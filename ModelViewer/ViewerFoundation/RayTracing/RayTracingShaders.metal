//
//  NuoRayTracingShaders.metal
//  ModelViewer
//
//  Created by middleware on 6/11/18.
//  Copyright © 2018 middleware. All rights reserved.
//

#include <metal_stdlib>

#include "NuoRayTracingUniform.h"
#include "RayTracingShadersCommon.h"

#define SIMPLE_UTILS_ONLY 1
#include "Meshes/ShadersCommon.h"


using namespace metal;



static RayBuffer primary_ray(matrix44 viewTrans, float3 endPoint)
{
    RayBuffer ray;
    
    float4 rayDirection = float4(normalize(endPoint), 0.0);
    
    ray.direction = (viewTrans * rayDirection).xyz;
    ray.origin = (viewTrans * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    
    return ray;
}



uint surface_mask(uint rayIdx, device RayStructureUniform& structUniform)
{
    device Intersection & intersection = structUniform.intersections[rayIdx];
    unsigned int triangleIndex = intersection.primitiveIndex;
    return structUniform.masks[triangleIndex];
}


#pragma mark -- Primary / Shadow Ray Emission, General Ray Mask

kernel void primary_ray_emit(uint2 tid [[thread_position_in_grid]],
                             constant NuoRayVolumeUniform& uniforms [[buffer(0)]],
                             device RayBuffer* rays [[buffer(1)]],
                             device NuoRayTracingRandomUnit* random [[buffer(2)]])
{
    if (!(tid.x < uniforms.wViewPort && tid.y < uniforms.hViewPort))
        return;
    
    unsigned int rayIdx = tid.y * uniforms.wViewPort + tid.x;
    device RayBuffer& ray = rays[rayIdx];
    
    device float2& r = random[(tid.y % 16) * 16 + (tid.x % 16)].uv;
    const float2 pixelCoord = (float2)tid + r;;
    
    const float u = (pixelCoord.x / (float)uniforms.wViewPort) * uniforms.uRange - uniforms.uRange / 2.0;
    const float v = (pixelCoord.y / (float)uniforms.hViewPort) * uniforms.vRange - uniforms.vRange / 2.0;
    
    ray = primary_ray(uniforms.viewTrans, float3(u, -v, -1.0));
    ray.pathScatter = float3(1.0, 1.0, 1.0);
    
    // primary rays are generated with mask as opaque. rays for translucent mask are got by
    // set the mask later by "ray_set_mask"
    //
    ray.mask = kNuoRayMask_Opaque;
    
    ray.bounce = 0;
    ray.opacity = -1.0;
    ray.primaryHitMask = 0;
    ray.ambientIlluminated = false;
    
    ray.maxDistance = INFINITY;
}



kernel void ray_set_mask(uint2 tid [[thread_position_in_grid]],
                         constant NuoRayVolumeUniform& uniforms [[buffer(0)]],
                         device uint* rayMask [[buffer(1)]],
                         device RayBuffer* rays [[buffer(2)]])
{
    if (!(tid.x < uniforms.wViewPort && tid.y < uniforms.hViewPort))
        return;
    
    unsigned int rayIdx = tid.y * uniforms.wViewPort + tid.x;
    device RayBuffer& ray = rays[rayIdx];
    
    // rays are used for calculate the ambient, so both translucent and opaque are detected upon.
    // this implies the ambient of objects behind translucent objects is ignored
    //
    ray.mask = *rayMask;
}


kernel void ray_set_mask_illuminating(uint2 tid [[thread_position_in_grid]],
                                      constant NuoRayVolumeUniform& uniforms [[buffer(0)]],
                                      device RayBuffer* rays [[buffer(1)]])
{
    if (!(tid.x < uniforms.wViewPort && tid.y < uniforms.hViewPort))
        return;
    
    unsigned int rayIdx = tid.y * uniforms.wViewPort + tid.x;
    device RayBuffer& ray = rays[rayIdx];
    
    ray.mask = kNuoRayMask_Illuminating;
}


void ambient_with_no_block(uint2 tid,
                           device RayStructureUniform& structUniform,
                           constant NuoRayTracingUniforms& tracingUniforms,
                           thread const RayBuffer& cameraRay,
                           device Intersection& intersection,
                           device NuoRayTracingRandomUnit& randomVars,
                           texture2d<float, access::read_write> target,
                           array<texture2d<float>, kTextureBindingsCap> diffuseTex,
                           sampler samplr)
{
    constant NuoRayTracingGlobalIlluminationParam& globalIllum = tracingUniforms.globalIllum;
    
    if (intersection.distance >= 0.0f)
    {
        device uint* index = structUniform.index;
        device NuoRayTracingMaterial* materials = structUniform.materials;
        const float maxDistance = tracingUniforms.bounds.span;
        
        NuoRayTracingMaterial material = interpolate_full_material(materials, diffuseTex,
                                                                   tracingUniforms.globalIllum.specularMaterialAdjust / 3.0,
                                                                   index, intersection, samplr);
        
        RayBuffer incidentRay;
        sample_scatter_ray(maxDistance, randomVars, intersection, material, cameraRay, incidentRay);
        
        float3 ambientColor = incidentRay.pathScatter * globalIllum.ambient;
        target.write(float4(ambientColor, 1.0), tid);
    }
    else
    {
        target.write(float4(globalIllum.ambient, 1.0), tid);
    }
}


void shadow_ray_emit_infinite_area(thread const RayBuffer& ray,
                                   device Intersection& intersection,
                                   device RayStructureUniform& structUniform,
                                   constant NuoRayTracingUniforms& tracingUniforms,
                                   constant NuoRayTracingLightSource& lightSource,
                                   float2 random,
                                   device RayBuffer* shadowRay,
                                   metal::array<metal::texture2d<float>, kTextureBindingsCap> diffuseTex,
                                   metal::sampler samplr)
{
    device NuoRayTracingMaterial* materials = structUniform.materials;
    device uint* index = structUniform.index;
    
    const float maxDistance = tracingUniforms.bounds.span;
    
    // initialize the buffer's path scatter fields
    // (took 2 days to figure this out after spot the problem in debugger 8/21/2018)
    //
    shadowRay->pathScatter = 0.0f;
    
    shadowRay->bounce = ray.bounce + 1;
    
    if (intersection.distance >= 0.0f)
    {
        float4 lightVec = float4(0.0, 0.0, 1.0, 0.0);
        lightVec = normalize(lightSource.direction * lightVec);
        
        float3 shadowVec = sample_cone_uniform(random, lightSource.coneAngleCosine);
        shadowVec = align_hemisphere_normal(shadowVec, lightVec.xyz);
        
        shadowRay->maxDistance = maxDistance;
        
        // either opaque blocker is checked, or no blocker is considered at all (for getting the
        // denominator light amount)
        //
        shadowRay->mask = kNuoRayMask_Opaque;
        
        NuoRayTracingMaterial material = interpolate_full_material(materials, diffuseTex,
                                                                   // try to normalize to uphold Cdiff + Cspec < 1.0
                                                                   // this is best effort and user trial-and-error as OBJ is not always PBR
                                                                   //
                                                                   tracingUniforms.globalIllum.specularMaterialAdjust / 3.0,
                                                                   index, intersection, samplr);
        
        float3 normal = material.normal;
        float3 intersectionPoint = ray.origin + ray.direction * intersection.distance;
        shadowRay->origin = intersectionPoint + normalize(normal) * (maxDistance / 20000.0);
        shadowRay->direction = shadowVec;
        shadowRay->primaryHitMask = ray.primaryHitMask;
        
        // calculate a specular term which is normalized according to the diffuse term
        //
        
        float specularPower = material.shinessDisolveIllum.x;
        float3 eyeDirection = -ray.direction;
        float3 halfway = normalize(shadowVec + eyeDirection);
        
        // for now, the diffuse term is not reduced by the translucent factor as it is in the
        // scattering-path-construction. this results in closer result to the rasterization/hybrid,
        // whose reason is yet to be analyzed
        //
        float3 diffuseTerm = material.diffuseColor;
        float3 specularTerm = specular_common_physically(material.specularColor, specularPower,
                                                         shadowVec, normal, halfway);
        
        // whether or not to adjust the reflection factor is arbitrary depending on how material
        // is defined. most OBJ models define it in a way that Cdiff need to be down-scaled. the scatter
        // sampling function does the same thing (see sample_scatter())
        //
        float surfaceOpacity = material.shinessDisolveIllum.y;
        surfaceOpacity = (1.0 - surfaceOpacity) < 1e-6 ? 1.0 : surfaceOpacity;
        diffuseTerm *= surfaceOpacity;
        
        // TODO: this is an extremly rough way of getting opacity. need a dedicated loop to calculate
        //       the real visibility
        //
        shadowRay->opacity = ray.opacity < 0.0 ? surfaceOpacity : ray.opacity;
        
        // the cosine factor is counted into the path scatter term, as the geometric coupling term,
        // because samples are generated from an inifinit distant area light (uniform on a finit
        // contending solid angle)
        //
        // specular and diffuse is normalized and scale as half-half
        //
        shadowRay->pathScatter = (diffuseTerm + specularTerm) * dot(normal, shadowVec);
    }
    else
    {
        shadowRay->maxDistance = -1.0;
    }
}



uint light_source_select(constant NuoRayTracingUniforms& tracingUniforms,
                         float random, thread float* totalDensity)
{
    float2 lightRandomRegion = float2(0);
    *totalDensity = 0;
    
    for (uint i = 0; i < 2; ++i)
        *totalDensity += tracingUniforms.lightSources[i].density;

    for (uint i = 0; i < 2; ++i)
    {
        float randomRegionSize = tracingUniforms.lightSources[i].density / (*totalDensity);
        lightRandomRegion.y = lightRandomRegion.x + randomRegionSize;
        
        if (random >= lightRandomRegion.x && random < lightRandomRegion.y)
            return i;
        
        lightRandomRegion.x = lightRandomRegion.y;
    }
    
    return 0;
}


inline static float3 reflection_vector(float3 wo, float3 normal);
inline bool same_hemisphere(float3 w, float3 wp);


static PathSample sample_scatter(thread const NuoRayTracingMaterial& material,
                                 float3 ray, float rayOpacity,
                                 float2 sampleUV, float Cdeterminator  /* randoms */ )
{
    PathSample result;
    
    const float3 Cdiff = material.diffuseColor;
    const float3 Cspec = material.specularColor;
    const float Mspec = material.shinessDisolveIllum.x;
    const float3 normal = material.normal;
    
    float CdiffSampleProbable = max(Cdiff.x, max(Cdiff.y, Cdiff.z));
    float CspecSampleProbable = min(Cspec.x, min(Cspec.y, Cspec.z));
    
    float transmissionPercent = 1.0 - material.shinessDisolveIllum.y;
    float Tr = transmissionPercent > 1e-6 ? transmissionPercent : 0.0;
    float probableTotal = CdiffSampleProbable * (1.0 - Tr) + CspecSampleProbable + Tr;
    
    result.transmission = false;
    result.opacity = rayOpacity < 0.0 ? (1 - Tr) : rayOpacity;
    
    // transmission (first branch) and two types of reflections
    //
    // to retain the parity with shadow_ray_emit_infinite_area, Cdiff is down-scaled
    // by the opacity
    
    if (Cdeterminator < Tr / probableTotal)
    {
        result.direction = -ray;
        result.pathScatterTerm = probableTotal;
        result.transmission = true;
        
        // transmiting rays are sampled by the importance of translucency so their opacity is
        // divided by Tr, reflected rays are sampled by the importance of surface
        // reflection so the opacity is assigned to the rays directly
        //
        result.opacity = 1.0 / Tr;
    }
    else if (Cdeterminator < (Tr + CdiffSampleProbable * (1.0 - Tr)) / probableTotal)
    {
        float3 wi = sample_cosine_weighted_hemisphere(sampleUV, 1);
        result.direction = align_hemisphere_normal(wi, normal);
        result.pathScatterTerm = Cdiff * (probableTotal / CdiffSampleProbable);
    }
    else
    {
        float3 wo = relative_to_hemisphere_normal(ray, normal);
        float3 wh = sample_cosine_weighted_hemisphere(sampleUV, Mspec);
        float3 wi = reflection_vector(wo, wh);
        
        if (!same_hemisphere(wo, wi))
        {
            result.pathScatterTerm = 0.0;
            return result;
        }
        
        // all the following factor omit a 1/pi factor, which would have been cancelled
        // in the calculation of cosinedPdfScale anyway
        //
        // hwPdf  -   PDF of the half vector in terms of theta_h, which is a cosine-weighed
        //            distribution based on micro-facet (and simplified by the Blinn-Phong).
        //            see comments in cosine_pow_pdf()
        //
        // f      -   BRDF specular term. note the normalization factor is (m + 8) / (8 * pi) because
        //            it is related to theta rather than theta_h.
        //            for the details of how the above normalization term is deduced, see http://www.farbrausch.de/%7Efg/stuff/phong.pdf
        //
        // pdf    -   PDF of the reflection vector. note this is not a analytical form in terms of theta,
        //            rather it is a value in terms of wo and the half-vector
        //            see p813, pbr-book
        //
        float hwPdf = (Mspec + 2.0) / 2.0;
        float pdf = hwPdf / (4.0 * dot(wo, wh));
        float3 f = specular_refectance_normalized(Cspec, Mspec, wo, wh);
        
        result.pathScatterTerm = f * (probableTotal / CspecSampleProbable) / pdf * wi.y /* cosine factor of incident ray */;
        result.direction = align_hemisphere_normal(wi, normal);
    }
    
    return result;
}


inline static float3 reflection_vector(float3 wo, float3 normal)
{
    return -wo + 2 * dot(wo, normal) * normal;
}


inline bool same_hemisphere(float3 w, float3 wp)
{
    return w.y * wp.y > 0;
}



void sample_scatter_ray(float maxDistance,
                        device NuoRayTracingRandomUnit& random,
                        device Intersection& intersection,
                        thread const NuoRayTracingMaterial& material,
                        thread const RayBuffer& ray,
                        thread RayBuffer& incidentRay)
{
    device float2& r = random.uv;
    device float& Cdeterm = random.pathTermDeterminator;
    float3 intersectionPoint = ray.origin + ray.direction * intersection.distance;

    PathSample sample = sample_scatter(material, -ray.direction, ray.opacity, r, Cdeterm);
    
    incidentRay.bounce = ray.bounce + 1;

    // terminate further tracing if the term is zero. this happens when the vector is out of
    // the hemisphere in the specular sampling
    //
    if (sample.pathScatterTerm.x == 0 &&
        sample.pathScatterTerm.y == 0 &&
        sample.pathScatterTerm.z == 0)
    {
        incidentRay.maxDistance = -1;
        incidentRay.pathScatter = 0.0;
    }
    else
    {
        incidentRay.direction = sample.direction;
        incidentRay.maxDistance = maxDistance;
        incidentRay.mask = kNuoRayMask_Opaque | kNuoRayMask_Virtual | kNuoRayMask_Illuminating;
        incidentRay.primaryHitMask = ray.primaryHitMask;
        incidentRay.opacity = sample.opacity;
        
        // different calculation for origin and ambient between transmission and reflection.
        //
        float3 normal =  sample.transmission ? -normalize(material.normal) : normalize(material.normal);
        incidentRay.origin = intersectionPoint + normal * (maxDistance / 20000.0);
        incidentRay.ambientIlluminated = ray.ambientIlluminated || sample.transmission;
        
        // make the term of this reflection contribute to the path scatter
        //
        incidentRay.pathScatter = sample.pathScatterTerm * ray.pathScatter;
    }
}


float ambient_distance_factor(float criteriaBlock, float criteriaUnblock,
                              float intersection, float power)
{
    if (intersection < criteriaBlock)
    {
        return 0.0;
    }
    
    if (intersection > criteriaUnblock)
    {
        return 1.0;
    }
    
    return pow((intersection - criteriaBlock) / (criteriaUnblock - criteriaBlock), power);
}




#pragma mark -- Debug Tools


/**
 *  debug tools
 */

kernel void intersection_visualize(uint2 tid [[thread_position_in_grid]],
                                   constant NuoRayVolumeUniform& uniforms [[buffer(0)]],
                                   device RayBuffer* rays [[buffer(1)]],
                                   device Intersection *intersections [[buffer(2)]],
                                   texture2d<float, access::write> dstTex [[texture(0)]])
{
    if (!(tid.x < uniforms.wViewPort && tid.y < uniforms.hViewPort))
        return;
    
    unsigned int rayIdx = tid.y * uniforms.wViewPort + tid.x;
    device Intersection & intersection = intersections[rayIdx];
    
    if (intersection.distance >= 0.0f)
    {
        dstTex.write(float4(1.0, 0.0, 0.0, 1.0f), tid);
    }
}




kernel void light_direction_visualize(uint2 tid [[thread_position_in_grid]],
                                      constant NuoRayVolumeUniform& uniforms [[buffer(0)]],
                                      device RayBuffer* rays [[buffer(1)]],
                                      device Intersection *intersections [[buffer(2)]],
                                      constant NuoRayTracingUniforms& tracingUniforms [[buffer(3)]],
                                      texture2d<float, access::write> dstTex [[texture(0)]])
{
    if (!(tid.x < uniforms.wViewPort && tid.y < uniforms.hViewPort))
        return;
    
    unsigned int rayIdx = tid.y * uniforms.wViewPort + tid.x;
    device Intersection & intersection = intersections[rayIdx];
    
    if (intersection.distance >= 0.0f)
    {
        float4 lightVec = float4(0.0, 0.0, 1.0, 0.0);
        lightVec = tracingUniforms.lightSources[0].direction * lightVec;
        dstTex.write(float4(lightVec.x, lightVec.y, 0.0, 1.0f), tid);
    }
}



