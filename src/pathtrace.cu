#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1
#define SORT_BY_MATERIAL 0
#define CACHE_FIRST_BOUNCE 1
#define ANTI_ALIASING 0

#define DOF 0
#define LENS_RADIUS 0.4
#define FOCAL_DISTANCE 8

#define MOTION_BLUR 0

#define BOUNDINGBOX 1

#define EDGE_VOIDING 1

#define GBUFFER_VIS_TYPE 2

enum VIS_TYPE
{
	T = 0,
	POS = 1,
	NOR = 2
};

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		float timeToIntersect = gBuffer[index].t * 256.0;

		if (GBUFFER_VIS_TYPE == VIS_TYPE::POS) {
			glm::vec3 pos = gBuffer[index].pos;
			pos = glm::clamp(abs(pos * 20.f), 0.f, 255.f);
			pbo[index].w = 0;
			pbo[index].x = pos.x;
			pbo[index].y = pos.y;
			pbo[index].z = pos.z;
		}
		else if (GBUFFER_VIS_TYPE == VIS_TYPE::NOR) {
			glm::vec3 nor = gBuffer[index].nor;
			nor = glm::clamp(abs(nor * 255.f), 0.f, 255.f);
			pbo[index].w = 1;
			pbo[index].x = nor.x;
			pbo[index].y = nor.y;
			pbo[index].z = nor.z;
		}
		else {
			pbo[index].w = 0;
			pbo[index].x = timeToIntersect;
			pbo[index].y = timeToIntersect;
			pbo[index].z = timeToIntersect;
		}
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
static ShadeableIntersection* dev_intersections_cache = NULL;
static Triangle* dev_triangles = NULL;
static GBufferPixel* dev_gBuffer = NULL;
static glm::vec3* dev_image_denoised = NULL;
static glm::vec3* dev_image_denoised_tmp = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// TODO: initialize any extra device memeory you need
	// if geoms contain mesh, allocate dev_triangles for it
	if (scene->hasMesh && scene->meshGeomId != -1) {
		Geom mesh = scene->geoms[scene->meshGeomId];
		cudaMalloc(&dev_triangles, mesh.numOfTriangles * sizeof(Triangle));
		cudaMemcpy(dev_triangles, mesh.triangles, mesh.numOfTriangles * sizeof(Triangle), cudaMemcpyHostToDevice);
	}

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));

	cudaMalloc(&dev_image_denoised, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image_denoised, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_image_denoised_tmp, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image_denoised_tmp, 0, pixelcount * sizeof(glm::vec3));


#if CACHE_FIRST_BOUNCE
	cudaMalloc(&dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections_cache, 0, pixelcount * sizeof(ShadeableIntersection));
#endif

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created
	cudaFree(dev_triangles);

#if CACHE_FIRST_BOUNCE
	cudaFree(dev_intersections_cache);
#endif

	cudaFree(dev_gBuffer);
	cudaFree(dev_image_denoised);
	cudaFree(dev_image_denoised_tmp);
	checkCUDAError("pathtraceFree");
}


__host__ __device__
glm::vec3 concentricSampleDisk(const glm::vec2& sampler) {
	float x = sampler.x;
	float y = sampler.y;
	float phi, r;
	float a = 2 * x - 1.f;
	float b = 2 * y - 1.f;

	if (a > -b) {
		if (a > b) {
			r = a;
			phi = (PI / 4) * (b / a);
		}
		else {
			r = b;
			phi = (PI / 4) * (2 - (a / b));
		}
	}
	else {
		if (a < b) {
			r = -a;
			phi = (PI / 4) * (4 + (b / a));
		}
		else {
			r = -b;
			if (b < 0 || b > 0) {
				phi = (PI / 4) * (6 - (a / b));
			}
			else {
				phi = 0;
			}
		}
	}
	return glm::vec3(cosf(phi) * r, sinf(phi) * r, 0);
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);
		
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, x, y);
		thrust::uniform_real_distribution<float> u01(0, 1);

#if ANTI_ALIASING
		
		x += u01(rng) * 2.0;
		y += u01(rng) * 2.0;
#endif
		// TODO: implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#if DOF
		/*glm::vec3 lens = concentricSampleDisk(glm::vec2(u01(rng), u01(rng))) * (float)LENS_RADIUS;
		glm::vec3 point = segment.ray.origin + lens;
		glm::vec3 pFocus = segment.ray.origin + (float)FOCAL_DISTANCE * segment.ray.direction;

		segment.ray.origin = point;
		segment.ray.direction = glm::normalize(pFocus - point);*/

		//Sample point on lens
		glm::vec3 point = concentricSampleDisk(glm::vec2(u01(rng), u01(rng))) * (float)LENS_RADIUS;

		glm::vec3 ref = cam.position + (cam.view * (float)FOCAL_DISTANCE);

		float aspect = ((float)cam.resolution.x / (float)cam.resolution.y);
		float angle = glm::radians(cam.fov.y);
		glm::vec3 V = cam.up * (float)FOCAL_DISTANCE * tan(angle);
		glm::vec3 H = cam.right * (float)FOCAL_DISTANCE * aspect * tan(angle);

		float ndc_x = 1.f - ((float)x / cam.resolution.x) * 2.f;
		float ndc_y = 1.f - ((float)y / cam.resolution.y) * 2.f;

		//Compute point on plane of focus
		glm::vec3 pFocus = ref + ndc_x * H + ndc_y * V;

		//Update ray for effect of lens
		segment.ray.origin = cam.position + (cam.up * point.y) + (cam.right * point.x);
		segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);
#endif
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, Triangle* triangles
	, int geoms_size
	, ShadeableIntersection* intersections
	, int iter
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				if (MOTION_BLUR && geom.materialid != 7) {
					thrust::default_random_engine rng = makeSeededRandomEngine(iter, path_index, 0);
					thrust::uniform_real_distribution<float> u01(0, 1);
					//Jitter the ray randomly about any axes 
					Ray jittered = pathSegment.ray;
					jittered.origin += u01(rng) * glm::vec3(0.75f, 0.75f, 0.f);
					t = sphereIntersectionTest(geom, jittered, tmp_intersect, tmp_normal, outside);
				}
				else {
					t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				}
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?
			else if (geom.type == MESH) {
#if BOUNDINGBOX
				// If intersect with the boundingbox of the obj, then compute the actual intersection point
				if (boundingBoxIntersectionTest(geom.boundingbBox, pathSegment.ray)) {
					t = meshIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, triangles, outside);
				}
#else
				t = meshIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, triangles, outside);
#endif
			}
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < num_paths)
    {
        ShadeableIntersection intersection = shadeableIntersections[idx];
        // if the intersection exists...
        if (intersection.t > 0.0f) 
        {  
            // Set up the RNG
            thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
            thrust::uniform_real_distribution<float> u01(0, 1);

            Material material = materials[intersection.materialId];
            glm::vec3 materialColor = material.color;

            // If hit light
            if (material.emittance > 0.0f) {
            pathSegments[idx].color *= (materialColor * material.emittance);
            pathSegments[idx].remainingBounces = 0;
            }
            // Otherwise, do some pseudo-lighting computation. This is actually more
            // like what you would expect from shading in a rasterizer like OpenGL.
            // TODO: replace this! you should be able to start with basically a one-liner
            else {
                pathSegments[idx].remainingBounces -= 1;
                // multiply the rayColor by the material color
                pathSegments[idx].color *= materialColor;
                glm::vec3 isect = getPointOnRay(pathSegments[idx].ray, intersection.t);
                scatterRay(pathSegments[idx], isect, intersection.surfaceNormal, material, rng);
          
            }
        } 
        else {
            pathSegments[idx].color = glm::vec3(0.0f);
            pathSegments[idx].remainingBounces = 0;
        }
    }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct is_reach_max_depth
{
    __host__ __device__
        bool operator()(const PathSegment &path)
    {
        return path.remainingBounces != 0;
    }
};

struct sort_isect
{
    __host__ __device__
        bool operator()(const ShadeableIntersection& isect1, const ShadeableIntersection& isect2)
    {
        return isect1.materialId < isect2.materialId;
    }
};

__global__ void generateGBuffer(
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	GBufferPixel* gBuffer) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection isect = shadeableIntersections[idx];
		Ray ray = pathSegments[idx].ray;
		gBuffer[idx].t = isect.t;
		gBuffer[idx].pos = ray.origin + isect.t * ray.direction;
		gBuffer[idx].nor = isect.surfaceNormal;
	}
}

__global__ void kernDenoiseInit(int iteration, glm::ivec2 resolution, glm::vec3* image, glm::vec3* denoisedImage)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int idx = x + resolution.x * y;
		denoisedImage[idx].x = image[idx].x / iteration;
		denoisedImage[idx].y = image[idx].y / iteration;
		denoisedImage[idx].z = image[idx].z / iteration;
	}
}


__global__ void kernDenoise(glm::ivec2 resolution, glm::vec3* denoise1, glm::vec3* denoise2, GBufferPixel* gBuffer,
	float cPhi, float nPhi, float pPhi, int step)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	float kernel[5][5] = {
		0.003765,	0.015019,	0.023792,	0.015019,	0.003765,
		0.015019,	0.059912,	0.094907,	0.059912,	0.015019,
		0.023792,	0.094907,	0.150342,	0.094907,	0.023792,
		0.015019,	0.059912,	0.094907,	0.059912,	0.015019,
		0.003765,	0.015019,	0.023792,	0.015019,	0.003765,
	};

	if (x < resolution.x && y < resolution.y) {
		glm::vec3 sum = glm::vec3(0.f);
		int idx = x + resolution.x * y;
		glm::vec3 cval = denoise1[idx];
		glm::vec3 pval = gBuffer[idx].pos;
		glm::vec3 nval = gBuffer[idx].nor;

		float cumW = 0.f;
		for (int i = -2; i <= 2; i++) {
			for (int j = -2; j <= 2; j++) {
				int x0 = x + step * i;
				int y0 = y + step * j;

				float w = 1.0f;
				float h = kernel[i + 2][j + 2];

				if (x0 >= 0 && x0 < resolution.x && y0 >= 0 && y0 < resolution.y) {
					int curIdx = x0 + y0 * resolution.x;
					glm::vec3 ctmp = denoise1[curIdx];

#ifdef  EDGE_VOIDING
					glm::vec3 t = cval - ctmp;
					float dist2 = glm::dot(t, t);
					float c_w = glm::min(glm::exp(-dist2 / cPhi), 1.f);

					glm::vec3 ntmp = gBuffer[curIdx].nor;
					t = nval - ntmp;
					dist2 = glm::dot(t, t);
					float n_w = glm::min(glm::exp(-dist2 / nPhi), 1.f);

					glm::vec3 ptmp = gBuffer[curIdx].pos;
					t = pval - ptmp;
					dist2 = glm::dot(t, t);
					float p_w = glm::min(glm::exp(-dist2 / pPhi), 1.f);
					w = c_w * n_w * p_w;
#endif //  EDGE_VOIDING

					sum += ctmp * w * h;
					cumW += w * h;
				}
			}
		}
		denoise2[idx] = sum / cumW;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	// Empty gbuffer
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

    bool iterationComplete = false;
    while (!iterationComplete) {
        // clean shading chunks
        cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

        // tracing
        dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

		// Use the cached first bounce
		if (CACHE_FIRST_BOUNCE && !ANTI_ALIASING && depth == 0 && iter != 1) {
			cudaMemcpy(dev_intersections, dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		
		}
		else {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, dev_triangles
				, hst_scene->geoms.size()
				, dev_intersections
				, iter
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();

			// Cache first bounce
			if (CACHE_FIRST_BOUNCE && !ANTI_ALIASING && depth == 0 && iter == 1) {
				cudaMemcpy(dev_intersections_cache, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
		}

		if (depth == 0) {
			generateGBuffer << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}

        depth++;

#if SORT_BY_MATERIAL
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, sort_isect());
#endif
        // TODO:
        // --- Shading Stage ---
        // Shade path segments based on intersections and generate new rays by
        // evaluating the BSDF.
        // Start off with just a big kernel that handles all the different
        // materials you have in the scenefile.
        // TODO: compare between directly shading the path segments and shading
        // path segments that have been reshuffled to be contiguous in memory.

        shadeFakeMaterial<<<numblocksPathSegmentTracing, blockSize1d>>> (
        iter,
        num_paths,
        dev_intersections,
        dev_paths,
        dev_materials
        );

        // stream compaction
        dev_path_end = thrust::partition(thrust::device, dev_paths, dev_path_end, is_reach_max_depth());
        num_paths = dev_path_end - dev_paths;
        if (num_paths == 0) {
            iterationComplete = true;
        }
        else iterationComplete = false;

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
    }

    // Assemble this iteration and apply it to the image
    dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
    finalGather<<<numBlocksPixels, blockSize1d>>>(pixelcount, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	//// Send results to OpenGL buffer for rendering
	//sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

void showGBuffer(uchar4* pbo) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
	gbufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
}

void showImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
}

__global__ void sendDenoisedToPBO(uchar4* pbo, glm::ivec2 resolution, glm::vec3* denoised)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int idx = x + resolution.x * y;
		glm::vec3 pixel = denoised[idx];

		pbo[idx].w = 0;
		pbo[idx].x = glm::clamp((int)(pixel.x * 255.0), 0, 255);
		pbo[idx].y = glm::clamp((int)(pixel.y * 255.0), 0, 255);
		pbo[idx].z = glm::clamp((int)(pixel.z * 255.0), 0, 255);
	}
}

void showDenoisedImage(uchar4* pbo, int iter, float cPhi, float nPhi, float pPhi, float filterSize) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	const int pixelcount = cam.resolution.x * cam.resolution.y;

	kernDenoiseInit << <blocksPerGrid2d, blockSize2d >> > (iter, cam.resolution, dev_image, dev_image_denoised);

	int maxStepSize = filterSize < 5 ? 0 : floor(log2(filterSize / 5.f));

	for (int i = 1; i < maxStepSize; ++i) {
		kernDenoise << <blocksPerGrid2d, blockSize2d >> > (cam.resolution, dev_image_denoised, dev_image_denoised_tmp, dev_gBuffer,
			cPhi, nPhi, pPhi, i);
		std::swap(dev_image_denoised, dev_image_denoised_tmp);
	}

	sendDenoisedToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_image_denoised);

	cudaDeviceSynchronize();
	cudaMemcpy(hst_scene->state.image.data(), dev_image_denoised,
		cam.resolution.x * cam.resolution.y * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	cudaDeviceSynchronize();
}