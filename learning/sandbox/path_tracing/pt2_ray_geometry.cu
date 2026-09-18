// PT.2 相机射线、几何求交与可见性的 CPU 验收。
//
// 本节仍然没有蒙特卡洛、没有 BRDF、没有 CUDA kernel。目标是把“一条射线
// 打到场景里，谁先被打中、打在哪、法线朝哪”做成可手算对照的事实：
//
//   1. 像素中心 -> 世界空间射线  P(t) = O + t D，D 单位化，t ∈ [tMin, tMax]
//   2. 球体二次方程、三角形 Möller–Trumbore、AABB slab
//   3. 最近命中：同一条射线穿过多个物体时，只保留最小合法 t
//   4. 正反面法线、平行漏过、擦边、自相交 epsilon
//
// 诊断图写在本文件旁边：法线 / 深度 / primitive ID 三张 PPM。

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kSelfHitEps = 1.0e-4f;
constexpr float kRayTMin = 1.0e-4f;
constexpr float kRayTMax = 1.0e30f;

constexpr int kImageWidth = 64;
constexpr int kImageHeight = 64;

enum class PrimType : int {
  None = 0,
  Sphere = 1,
  Triangle = 2,
  Aabb = 3,
};

struct Vec3 {
  float x;
  float y;
  float z;
};

struct Ray {
  Vec3 o;
  Vec3 d;     // 必须单位化。P(t) = o + t d，t 是沿射线的欧氏距离。
  float tmin;
  float tmax;
};

struct Hit {
  float t;
  Vec3 p;
  Vec3 n;          // 几何法线，指向“正面”一侧；球体指向外侧。
  Vec3 bary;       // 三角形才有意义：(w0, w1, w2)，对应 v0/v1/v2。
  int prim_id;
  PrimType type;
  bool front_face; // dot(n, -d) > 0：射线从正面打进来。
};

struct Sphere {
  Vec3 center;
  float radius;
  int prim_id;
};

struct Triangle {
  Vec3 v0;
  Vec3 v1;
  Vec3 v2;
  int prim_id;
};

struct Aabb {
  Vec3 bmin;
  Vec3 bmax;
  int prim_id;
};

struct Camera {
  Vec3 origin;
  Vec3 lower_left;  // 胶片左下角在世界空间的点（像素 (0,H-1) 的外角）
  Vec3 horizontal;  // 胶片右方向，长度 = 视口宽度
  Vec3 vertical;    // 胶片上方向，长度 = 视口高度
  Vec3 u;           // 相机右，单位
  Vec3 v;           // 相机上，单位
  Vec3 w;           // 相机后（从 lookat 指向 origin），单位。前向是 -w。
  int width;
  int height;
};

struct Scene {
  Sphere sphere;
  Triangle triangle;
  Aabb aabb;
};

struct TestStats {
  int passed;
  int failed;
};

static Vec3 v3(float x, float y, float z) { return Vec3{x, y, z}; }

static Vec3 operator+(Vec3 a, Vec3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
static Vec3 operator-(Vec3 a, Vec3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
static Vec3 operator-(Vec3 a) { return v3(-a.x, -a.y, -a.z); }
static Vec3 operator*(Vec3 a, float s) { return v3(a.x * s, a.y * s, a.z * s); }

static float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

static Vec3 cross(Vec3 a, Vec3 b) {
  return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

static float length(Vec3 a) { return std::sqrt(dot(a, a)); }

static Vec3 normalize(Vec3 a) {
  const float len = length(a);
  return a * (1.0f / len);
}

static Vec3 at(const Ray& ray, float t) { return ray.o + ray.d * t; }

static float absf(float x) { return std::fabs(x); }

static bool nearly_equal(float a, float b, float tol = 1.0e-4f) {
  return absf(a - b) <= tol;
}

static bool nearly_equal_vec(Vec3 a, Vec3 b, float tol = 1.0e-4f) {
  return nearly_equal(a.x, b.x, tol) && nearly_equal(a.y, b.y, tol) &&
         nearly_equal(a.z, b.z, tol);
}

static Ray make_ray(Vec3 o, Vec3 d, float tmin = kRayTMin, float tmax = kRayTMax) {
  Ray ray;
  ray.o = o;
  ray.d = normalize(d);
  ray.tmin = tmin;
  ray.tmax = tmax;
  return ray;
}

static void clear_hit(Hit* hit) {
  hit->t = kRayTMax;
  hit->p = v3(0.0f, 0.0f, 0.0f);
  hit->n = v3(0.0f, 0.0f, 0.0f);
  hit->bary = v3(0.0f, 0.0f, 0.0f);
  hit->prim_id = 0;
  hit->type = PrimType::None;
  hit->front_face = false;
}

static void finish_hit(Hit* hit, const Ray& ray, Vec3 n, int prim_id, PrimType type,
                       Vec3 bary) {
  hit->p = at(ray, hit->t);
  // 几何法线先按图元定义写入；再按射线方向判断正反面。
  // 球体：n 指向外侧。三角形：n = normalize((v1-v0)×(v2-v0))，右手螺旋。
  // 正面：射线从法线一侧打进来，即 n · (-d) > 0。
  const float facing = dot(n, -ray.d);
  hit->n = n;
  hit->front_face = facing > 0.0f;
  hit->prim_id = prim_id;
  hit->type = type;
  hit->bary = bary;
}

// -----------------------------------------------------------------------------
// 相机：针孔。世界空间里先摆一张成像平面，再把像素格子铺到这张平面上。
// 这是投影的逆，不是“像素自己已经是世界坐标”。
//
//   平面立在针孔前方 1 个世界单位，垂直于视线，大小由 FOV 决定。
//   像素 (x,y) 的中心 = 这张世界矩形上对应格子的中心点 P_film。
//   射线 = 从针孔射向 P_film。
//
// 这张平面是虚拟胶片 / image plane，不是光学焦平面（焦平面是薄透镜对焦面，景深才用）。
// 求交在世界空间，不进 NDC，也不走 D3D12 RSSetViewports。
// -----------------------------------------------------------------------------
static Camera make_camera(Vec3 origin, Vec3 look_at, Vec3 world_up, float vfov_deg,
                          int width, int height) {
  const float aspect = static_cast<float>(width) / static_cast<float>(height);
  const float theta = vfov_deg * kPi / 180.0f;
  const float viewport_height = 2.0f * std::tan(theta * 0.5f);
  const float viewport_width = aspect * viewport_height;

  // w 指向相机后方。前向是 -w，和 OpenGL/UE 观察空间 -Z 前向同一约定。
  const Vec3 w = normalize(origin - look_at);
  const Vec3 u = normalize(cross(world_up, w));
  const Vec3 v = cross(w, u);

  Camera cam;
  cam.origin = origin;
  cam.horizontal = u * viewport_width;
  cam.vertical = v * viewport_height;
  cam.lower_left = origin - cam.horizontal * 0.5f - cam.vertical * 0.5f - w;
  cam.u = u;
  cam.v = v;
  cam.w = w;
  cam.width = width;
  cam.height = height;
  return cam;
}

// 像素格子均匀铺在世界成像平面上。+0.5 取格子中心；除以宽高得到平面上的比例。
// y=0 是图像顶行，平面的 vertical 从下往上，所以用 (1-ty)。
static Ray camera_ray(const Camera& cam, float pixel_x, float pixel_y) {
  const float s = (pixel_x + 0.5f) / static_cast<float>(cam.width);
  const float ty = (pixel_y + 0.5f) / static_cast<float>(cam.height);
  const Vec3 on_film =
      cam.lower_left + cam.horizontal * s + cam.vertical * (1.0f - ty);
  return make_ray(cam.origin, on_film - cam.origin);
}

// -----------------------------------------------------------------------------
// 球体：|O + t D - C|^2 = r^2
//   a t^2 + 2 b t + c = 0，其中
//   a = D·D = 1（D 已单位化）
//   b = D·(O-C)
//   c = |O-C|^2 - r^2
// 判别式 Δ = b^2 - c。Δ<0 漏过；Δ=0 擦边一个根；Δ>0 两个根（近/远）。
// 有效根必须落在 [tmin, tmax]。
// -----------------------------------------------------------------------------
static bool intersect_sphere(const Ray& ray, const Sphere& sphere, Hit* hit) {
  const Vec3 oc = ray.o - sphere.center;
  const float b = dot(ray.d, oc);
  const float c = dot(oc, oc) - sphere.radius * sphere.radius;
  const float disc = b * b - c;
  if (disc < 0.0f) {
    return false;
  }
  const float sqrt_disc = std::sqrt(disc);
  float t = -b - sqrt_disc;  // 较近根
  if (t < ray.tmin || t > ray.tmax) {
    t = -b + sqrt_disc;  // 可能从内部出发，或近根被 tmin 裁掉
    if (t < ray.tmin || t > ray.tmax) {
      return false;
    }
  }
  hit->t = t;
  const Vec3 p = at(ray, t);
  const Vec3 n = (p - sphere.center) * (1.0f / sphere.radius);
  finish_hit(hit, ray, n, sphere.prim_id, PrimType::Sphere, v3(0.0f, 0.0f, 0.0f));
  return true;
}

// -----------------------------------------------------------------------------
// 三角形求交就是解 3×3 线性方程组，不是另一种几何。
//
//   O + t D = v0 + u (v1-v0) + v (v2-v0)
//   [-D | e1 | e2] [t u v]^T = O - v0
//
// Möller–Trumbore 用标量三重积做克拉默法则，不显式求逆、不构造平面。
// det = e1 · (D × e2) 就是那个 3×3 矩阵的行列式（差一个符号约定）。
// |det|≈0：射线与平面平行（含共面），方程组退化，漏过。
// u, v 是 v1、v2 的重心权重：P = (1-u-v) v0 + u v1 + v v2。
// 命中要求 u>=0, v>=0, u+v<=1，且 t ∈ [tmin,tmax]。
//
// 本课不背面剔除：透射、阴影射线都可能从背面进来。只标记 front_face。
// -----------------------------------------------------------------------------
static bool intersect_triangle(const Ray& ray, const Triangle& tri, Hit* hit) {
  const Vec3 e1 = tri.v1 - tri.v0;
  const Vec3 e2 = tri.v2 - tri.v0;
  const Vec3 pvec = cross(ray.d, e2);
  const float det = dot(e1, pvec);
  if (absf(det) < 1.0e-8f) {
    return false;  // 平行或共面
  }
  const float inv_det = 1.0f / det;
  const Vec3 tvec = ray.o - tri.v0;
  const float u = dot(tvec, pvec) * inv_det;
  if (u < 0.0f || u > 1.0f) {
    return false;
  }
  const Vec3 qvec = cross(tvec, e1);
  const float v = dot(ray.d, qvec) * inv_det;
  if (v < 0.0f || u + v > 1.0f) {
    return false;
  }
  const float t = dot(e2, qvec) * inv_det;
  if (t < ray.tmin || t > ray.tmax) {
    return false;
  }
  hit->t = t;
  const Vec3 n = normalize(cross(e1, e2));
  finish_hit(hit, ray, n, tri.prim_id, PrimType::Triangle, v3(1.0f - u - v, u, v));
  return true;
}

// -----------------------------------------------------------------------------
// AABB slab：把盒子看成三对平行平面。每对平面把射线裁成一段 [t_enter, t_exit]。
// 三段求交；空集就是漏过。
//
// 某轴方向分量为 0：射线平行于该对平面。原点在 slab 外则漏过，在内则这轴不裁。
// 原点在盒子内部：t_enter 为负。最近合法墙是 t_exit，不是 tmin。
// -----------------------------------------------------------------------------
static bool intersect_aabb(const Ray& ray, const Aabb& box, Hit* hit) {
  // 先算未经 [tmin,tmax] 裁剪的进入/离开时间。tmin 是射线有效区间，
  // 不能拿它当“进入时间”的初值，否则原点在盒子里时会把 t=0 当成墙。
  float t_enter = -kRayTMax;
  float t_exit = kRayTMax;
  const float* origin = &ray.o.x;
  const float* dir = &ray.d.x;
  const float* bmin = &box.bmin.x;
  const float* bmax = &box.bmax.x;

  for (int axis = 0; axis < 3; ++axis) {
    if (absf(dir[axis]) < 1.0e-8f) {
      if (origin[axis] < bmin[axis] || origin[axis] > bmax[axis]) {
        return false;
      }
      continue;
    }
    float t0 = (bmin[axis] - origin[axis]) / dir[axis];
    float t1 = (bmax[axis] - origin[axis]) / dir[axis];
    if (t0 > t1) {
      const float tmp = t0;
      t0 = t1;
      t1 = tmp;
    }
    t_enter = std::max(t_enter, t0);
    t_exit = std::min(t_exit, t1);
    if (t_enter > t_exit) {
      return false;
    }
  }

  // 从外面进来：最近墙是 t_enter。从里面往外走：t_enter < tmin，最近墙是 t_exit。
  float t = t_enter;
  if (t < ray.tmin) {
    t = t_exit;
  }
  if (t < ray.tmin || t > ray.tmax) {
    return false;
  }
  hit->t = t;
  const Vec3 p = at(ray, t);

  // 用命中点离哪块墙最近来估计法线。这是教学用的轴对齐法线，不是解析梯度。
  Vec3 n = v3(0.0f, 0.0f, 0.0f);
  const float dx_min = absf(p.x - box.bmin.x);
  const float dx_max = absf(p.x - box.bmax.x);
  const float dy_min = absf(p.y - box.bmin.y);
  const float dy_max = absf(p.y - box.bmax.y);
  const float dz_min = absf(p.z - box.bmin.z);
  const float dz_max = absf(p.z - box.bmax.z);
  const float nearest = std::min({dx_min, dx_max, dy_min, dy_max, dz_min, dz_max});
  if (nearest == dx_min) {
    n = v3(-1.0f, 0.0f, 0.0f);
  } else if (nearest == dx_max) {
    n = v3(1.0f, 0.0f, 0.0f);
  } else if (nearest == dy_min) {
    n = v3(0.0f, -1.0f, 0.0f);
  } else if (nearest == dy_max) {
    n = v3(0.0f, 1.0f, 0.0f);
  } else if (nearest == dz_min) {
    n = v3(0.0f, 0.0f, -1.0f);
  } else {
    n = v3(0.0f, 0.0f, 1.0f);
  }
  finish_hit(hit, ray, n, box.prim_id, PrimType::Aabb, v3(0.0f, 0.0f, 0.0f));
  return true;
}

static bool closest_hit(const Ray& ray, const Scene& scene, Hit* hit) {
  clear_hit(hit);
  bool any = false;
  Hit candidate;
  Ray shrinking = ray;

  if (intersect_sphere(shrinking, scene.sphere, &candidate)) {
    shrinking.tmax = candidate.t;
    *hit = candidate;
    any = true;
  }
  if (intersect_triangle(shrinking, scene.triangle, &candidate)) {
    shrinking.tmax = candidate.t;
    *hit = candidate;
    any = true;
  }
  if (intersect_aabb(shrinking, scene.aabb, &candidate)) {
    shrinking.tmax = candidate.t;
    *hit = candidate;
    any = true;
  }
  return any;
}

static void record(TestStats* stats, const char* name, bool ok) {
  stats->passed += ok ? 1 : 0;
  stats->failed += ok ? 0 : 1;
  std::printf("  %-48s %s\n", name, ok ? "PASS" : "FAIL");
}

static std::string sibling_path(const char* file_name) {
  const std::string here = __FILE__;
  const std::size_t slash = here.find_last_of("/\\");
  if (slash == std::string::npos) {
    return file_name;
  }
  return here.substr(0, slash + 1) + file_name;
}

static std::uint8_t to_byte(float x) {
  const int v = static_cast<int>(std::floor(x * 255.0f + 0.5f));
  return static_cast<std::uint8_t>(std::min(255, std::max(0, v)));
}

static bool write_ppm(const std::string& path, int width, int height,
                      const std::uint8_t* rgb) {
  std::FILE* file = std::fopen(path.c_str(), "wb");
  if (!file) {
    std::printf("failed to write %s\n", path.c_str());
    return false;
  }
  std::fprintf(file, "P6\n%d %d\n255\n", width, height);
  const std::size_t bytes = static_cast<std::size_t>(width * height * 3);
  const bool ok = std::fwrite(rgb, 1, bytes, file) == bytes;
  std::fclose(file);
  return ok;
}

}  // namespace

int main() {
  TestStats stats = {};
  std::printf("PT.2 camera rays / sphere / triangle / AABB\n\n");

  // ---------------------------------------------------------------------------
  // 手算场景。数字全部选成能口算或最多开一次根号。
  //
  // 相机：原点 (0,0,0)，看向 -Z，上向量 +Y，垂直 FOV 90°。
  //   tan(45°)=1，正方形胶片，视口宽高都是 2，焦点距离 1。
  //   前向 -w = (0,0,-1)，右 u=(1,0,0)，上 v=(0,1,0)。
  //
  // 球体：C=(0,0,-2)，r=1。沿 -Z 的射线：
  //   (t-1)(t-3)=0 → 近根 t=1，点 (0,0,-1)，外侧法线 (0,0,1)。
  //
  // 三角形：A=(0,1,-1), B=(-1,-1,-1), C=(1,-1,-1)，在 z=-1 平面，CCW 朝 +Z。
  //   沿 -Z 打中心：t=1，P=(0,0,-1)，重心 (0.5, 0.25, 0.25)，法线 (0,0,1)。
  //
  // AABB：[-0.5,-0.5,-2.5]..[0.5,0.5,-1.5]。沿 -Z：先碰到 z=max 墙，t=1.5。
  // ---------------------------------------------------------------------------
  const Camera cam = make_camera(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f),
                                 v3(0.0f, 1.0f, 0.0f), 90.0f, 2, 2);
  const Sphere sphere = {v3(0.0f, 0.0f, -2.0f), 1.0f, 1};
  const Triangle triangle = {v3(0.0f, 1.0f, -1.0f), v3(-1.0f, -1.0f, -1.0f),
                             v3(1.0f, -1.0f, -1.0f), 2};
  const Aabb aabb = {v3(-0.5f, -0.5f, -2.5f), v3(0.5f, 0.5f, -1.5f), 3};

  std::printf("1) camera basis and pixel-center rays\n");
  record(&stats, "camera u = +X", nearly_equal_vec(cam.u, v3(1.0f, 0.0f, 0.0f)));
  record(&stats, "camera v = +Y", nearly_equal_vec(cam.v, v3(0.0f, 1.0f, 0.0f)));
  record(&stats, "camera w = +Z (backward)",
         nearly_equal_vec(cam.w, v3(0.0f, 0.0f, 1.0f)));

  const Camera cam1 = make_camera(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f),
                                  v3(0.0f, 1.0f, 0.0f), 90.0f, 1, 1);
  const Ray center_ray = camera_ray(cam1, 0.0f, 0.0f);
  record(&stats, "1x1 pixel center looks down -Z",
         nearly_equal_vec(center_ray.d, v3(0.0f, 0.0f, -1.0f)));

  // 2x2 图像，像素 (0,0) 中心：
  //   s=0.25, 胶片 y 从上往下，t_film=0.75
  //   NDC 风格偏移：方向未归一化 = (-0.5, 0.5, -1)
  //   |d| = sqrt(1.5) ≈ 1.22474487
  const Ray pixel00 = camera_ray(cam, 0.0f, 0.0f);
  const float inv_len = 1.0f / std::sqrt(1.5f);
  const Vec3 expected00 = v3(-0.5f * inv_len, 0.5f * inv_len, -1.0f * inv_len);
  record(&stats, "2x2 pixel (0,0) direction", nearly_equal_vec(pixel00.d, expected00));
  record(&stats, "ray direction unit length", nearly_equal(length(pixel00.d), 1.0f));
  record(&stats, "P(t)=O+tD at t=0 is origin",
         nearly_equal_vec(at(pixel00, 0.0f), pixel00.o));

  std::printf("\n2) sphere: hit / miss / graze / back face\n");
  Hit hit;
  const Ray z_ray = make_ray(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "sphere front hit t=1",
         intersect_sphere(z_ray, sphere, &hit) && nearly_equal(hit.t, 1.0f) &&
             nearly_equal_vec(hit.p, v3(0.0f, 0.0f, -1.0f)) &&
             nearly_equal_vec(hit.n, v3(0.0f, 0.0f, 1.0f)) && hit.front_face &&
             hit.prim_id == 1);

  const Ray far_only = make_ray(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f), 1.5f);
  record(&stats, "tmin clips near root, far root t=3",
         intersect_sphere(far_only, sphere, &hit) && nearly_equal(hit.t, 3.0f) &&
             !hit.front_face);

  const Ray miss_sphere = make_ray(v3(0.0f, 1.5f, 0.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "sphere miss above", !intersect_sphere(miss_sphere, sphere, &hit));

  const Ray graze = make_ray(v3(0.0f, 1.0f, 0.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "sphere graze disc=0 t=2",
         intersect_sphere(graze, sphere, &hit) && nearly_equal(hit.t, 2.0f) &&
             nearly_equal_vec(hit.p, v3(0.0f, 1.0f, -2.0f)));

  std::printf("\n3) triangle: barycentric / parallel / backface\n");
  record(&stats, "triangle hit t=1 bary=(0.5,0.25,0.25)",
         intersect_triangle(z_ray, triangle, &hit) && nearly_equal(hit.t, 1.0f) &&
             nearly_equal_vec(hit.bary, v3(0.5f, 0.25f, 0.25f), 1.0e-4f) &&
             nearly_equal_vec(hit.n, v3(0.0f, 0.0f, 1.0f)) && hit.front_face);

  const Ray miss_tri = make_ray(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 3.0f, -1.0f), 0.0f);
  record(&stats, "triangle miss above apex",
         !intersect_triangle(miss_tri, triangle, &hit));

  const Ray parallel_tri = make_ray(v3(0.0f, 0.0f, -1.0f), v3(1.0f, 0.0f, 0.0f), 0.0f);
  record(&stats, "triangle parallel in-plane miss",
         !intersect_triangle(parallel_tri, triangle, &hit));

  const Ray back_tri = make_ray(v3(0.0f, 0.0f, -2.0f), v3(0.0f, 0.0f, 1.0f), 0.0f);
  record(&stats, "triangle backface t=1 front=false",
         intersect_triangle(back_tri, triangle, &hit) && nearly_equal(hit.t, 1.0f) &&
             nearly_equal_vec(hit.bary, v3(0.5f, 0.25f, 0.25f), 1.0e-4f) &&
             !hit.front_face);

  std::printf("\n4) AABB: hit / miss / parallel / inside\n");
  record(&stats, "AABB front wall t=1.5 n=+Z",
         intersect_aabb(z_ray, aabb, &hit) && nearly_equal(hit.t, 1.5f) &&
             nearly_equal_vec(hit.p, v3(0.0f, 0.0f, -1.5f)) &&
             nearly_equal_vec(hit.n, v3(0.0f, 0.0f, 1.0f)) && hit.front_face);

  const Ray miss_aabb = make_ray(v3(2.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "AABB miss to the right", !intersect_aabb(miss_aabb, aabb, &hit));

  const Ray parallel_aabb = make_ray(v3(2.0f, 0.0f, -2.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "AABB parallel outside X slab",
         !intersect_aabb(parallel_aabb, aabb, &hit));

  const Ray inside_aabb = make_ray(v3(0.0f, 0.0f, -2.0f), v3(0.0f, 0.0f, -1.0f), 0.0f);
  record(&stats, "AABB origin inside, exits at t=0.5",
         intersect_aabb(inside_aabb, aabb, &hit) && nearly_equal(hit.t, 0.5f));

  std::printf("\n5) closest hit and self-intersection epsilon\n");
  Scene scene;
  scene.sphere = sphere;
  scene.triangle = triangle;
  scene.aabb = aabb;
  record(&stats, "closest hit prefers triangle t=1 over sphere/AABB",
         closest_hit(z_ray, scene, &hit) && hit.prim_id == 2 &&
             nearly_equal(hit.t, 1.0f));

  // 把三角形挪走后，同一条 -Z 射线应先碰到 AABB t=1.5，而不是球体 t=1。
  Scene no_tri = scene;
  no_tri.triangle.v0 = v3(10.0f, 10.0f, -1.0f);
  no_tri.triangle.v1 = v3(11.0f, 10.0f, -1.0f);
  no_tri.triangle.v2 = v3(10.0f, 11.0f, -1.0f);
  // 去掉三角形后，球体近根 t=1 仍比 AABB 前墙 t=1.5 更近。
  record(&stats, "without triangle, sphere t=1 still beats AABB t=1.5",
         closest_hit(z_ray, no_tri, &hit) && hit.prim_id == 1 &&
             nearly_equal(hit.t, 1.0f));

  // 自相交：从球体正面命中点沿同一方向再出发。
  // tmin=0 会立刻再打到同一点（数值上 t≈0）；tmin=1e-4 跳过表面，打到背面 t≈2。
  Hit first_hit;
  intersect_sphere(z_ray, sphere, &first_hit);
  const Ray no_eps = make_ray(first_hit.p, z_ray.d, 0.0f);
  Hit self_hit;
  const bool self_again = intersect_sphere(no_eps, sphere, &self_hit);
  record(&stats, "tmin=0 re-hits same sphere near t=0",
         self_again && self_hit.t < 1.0e-3f);

  const Ray with_eps = make_ray(first_hit.p, z_ray.d, kSelfHitEps);
  record(&stats, "tmin=1e-4 skips surface, hits back t≈2",
         intersect_sphere(with_eps, sphere, &self_hit) &&
             nearly_equal(self_hit.t, 2.0f, 1.0e-3f) && !self_hit.front_face);

  // ---------------------------------------------------------------------------
  // 诊断图：64x64，相机仍是 90° 看 -Z。三个物体左右错开，避免完全叠在一起。
  // 法线：(-n*0.5+0.5) 编码。深度：t/6 压成灰度，越近越亮。ID：球红、三角绿、盒蓝。
  // ---------------------------------------------------------------------------
  std::printf("\n6) diagnostic images 64x64\n");
  Scene picture;
  picture.sphere = {v3(-0.15f, 0.05f, -3.0f), 0.85f, 1};
  picture.triangle = {v3(-1.55f, -0.35f, -2.2f), v3(-0.45f, -0.55f, -2.0f),
                      v3(-0.95f, 0.75f, -2.1f), 2};
  picture.aabb = {v3(0.55f, -0.55f, -2.35f), v3(1.35f, 0.45f, -1.55f), 3};
  const Camera pic_cam = make_camera(v3(0.0f, 0.0f, 0.0f), v3(0.0f, 0.0f, -1.0f),
                                     v3(0.0f, 1.0f, 0.0f), 90.0f, kImageWidth,
                                     kImageHeight);

  std::uint8_t normals[kImageWidth * kImageHeight * 3];
  std::uint8_t depth[kImageWidth * kImageHeight * 3];
  std::uint8_t prim_id[kImageWidth * kImageHeight * 3];
  int counts[4] = {};

  for (int y = 0; y < kImageHeight; ++y) {
    for (int x = 0; x < kImageWidth; ++x) {
      const Ray ray = camera_ray(pic_cam, static_cast<float>(x), static_cast<float>(y));
      Hit pix;
      const bool found = closest_hit(ray, picture, &pix);
      const int i = (y * kImageWidth + x) * 3;
      if (!found) {
        counts[0] += 1;
        normals[i + 0] = 16;
        normals[i + 1] = 16;
        normals[i + 2] = 16;
        depth[i + 0] = 0;
        depth[i + 1] = 0;
        depth[i + 2] = 0;
        prim_id[i + 0] = 0;
        prim_id[i + 1] = 0;
        prim_id[i + 2] = 0;
        continue;
      }
      counts[static_cast<int>(pix.type)] += 1;
      normals[i + 0] = to_byte(0.5f * pix.n.x + 0.5f);
      normals[i + 1] = to_byte(0.5f * pix.n.y + 0.5f);
      normals[i + 2] = to_byte(0.5f * pix.n.z + 0.5f);
      const float d = std::max(0.0f, 1.0f - pix.t / 6.0f);
      const std::uint8_t db = to_byte(d);
      depth[i + 0] = db;
      depth[i + 1] = db;
      depth[i + 2] = db;
      if (pix.type == PrimType::Sphere) {
        prim_id[i + 0] = 220;
        prim_id[i + 1] = 48;
        prim_id[i + 2] = 48;
      } else if (pix.type == PrimType::Triangle) {
        prim_id[i + 0] = 48;
        prim_id[i + 1] = 200;
        prim_id[i + 2] = 64;
      } else {
        prim_id[i + 0] = 48;
        prim_id[i + 1] = 96;
        prim_id[i + 2] = 220;
      }
    }
  }

  const std::string n_path = sibling_path("pt2_normals.ppm");
  const std::string d_path = sibling_path("pt2_depth.ppm");
  const std::string id_path = sibling_path("pt2_primid.ppm");
  const bool images_ok = write_ppm(n_path, kImageWidth, kImageHeight, normals) &&
                         write_ppm(d_path, kImageWidth, kImageHeight, depth) &&
                         write_ppm(id_path, kImageWidth, kImageHeight, prim_id);
  record(&stats, "wrote normal/depth/prim-id PPM", images_ok);
  record(&stats, "image contains sphere pixels", counts[1] > 50);
  record(&stats, "image contains triangle pixels", counts[2] > 20);
  record(&stats, "image contains AABB pixels", counts[3] > 20);
  record(&stats, "image contains misses", counts[0] > 50);

  // 抽三个已知像素：图像中心应打到球体；左侧应能打到三角形；右侧打到 AABB。
  Hit center;
  const bool center_hit =
      closest_hit(camera_ray(pic_cam, 32.0f, 32.0f), picture, &center);
  record(&stats, "pixel (32,32) hits sphere",
         center_hit && center.prim_id == 1);

  std::printf("\nimage coverage: miss=%d sphere=%d triangle=%d aabb=%d\n",
              counts[0], counts[1], counts[2], counts[3]);
  std::printf("wrote:\n  %s\n  %s\n  %s\n", n_path.c_str(), d_path.c_str(),
              id_path.c_str());

  std::printf("\n%d passed, %d failed\n", stats.passed, stats.failed);
  if (stats.failed != 0) {
    std::printf("PT.2 ray geometry: FAIL\n");
    return EXIT_FAILURE;
  }
  std::printf("PT.2 ray geometry: PASS\n");
  return EXIT_SUCCESS;
}
