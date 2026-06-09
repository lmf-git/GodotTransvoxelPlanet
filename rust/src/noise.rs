//! Hand-rolled 3D gradient (Perlin-style) noise with FBM and ridged fractals.
//! No external crates — full control over the basis. Output is normalised to
//! roughly [-1, 1] so the density composition (ported from density.gd) reads
//! the same ranges it expects. The look differs from Godot's FastNoiseLite, so
//! the planet's biomes/water/mountains will want re-tuning — that's the cost of
//! owning the noise outright.

#[derive(Clone, Copy)]
pub enum Fractal {
    Fbm,
    Ridged,
}

pub struct Noise {
    seed: i32,
    freq: f32,
    octaves: i32,
    lacunarity: f32,
    gain: f32,
    fractal: Fractal,
    bounding: f32, // 1 / sum(amp) so summed octaves stay ~[-1, 1]
}

// 12 edge-midpoint gradient directions (classic Perlin set).
const GRAD3: [[f32; 3]; 12] = [
    [1.0, 1.0, 0.0], [-1.0, 1.0, 0.0], [1.0, -1.0, 0.0], [-1.0, -1.0, 0.0],
    [1.0, 0.0, 1.0], [-1.0, 0.0, 1.0], [1.0, 0.0, -1.0], [-1.0, 0.0, -1.0],
    [0.0, 1.0, 1.0], [0.0, -1.0, 1.0], [0.0, 1.0, -1.0], [0.0, -1.0, -1.0],
];

// Integer lattice hash → well-mixed u32 (table-free, deterministic per seed).
#[inline]
fn hash(seed: i32, x: i32, y: i32, z: i32) -> u32 {
    let mut h = (seed as u32).wrapping_mul(0x9E3779B1);
    h ^= (x as u32).wrapping_mul(0x85EBCA77);
    h ^= (y as u32).wrapping_mul(0xC2B2AE3D);
    h ^= (z as u32).wrapping_mul(0x27D4EB2F);
    h = h.wrapping_mul(0x85EBCA77);
    h ^= h >> 13;
    h = h.wrapping_mul(0xC2B2AE3D);
    h ^ (h >> 16)
}

#[inline]
fn fade(t: f32) -> f32 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + t * (b - a)
}

#[inline]
fn grad_dot(seed: i32, ix: i32, iy: i32, iz: i32, fx: f32, fy: f32, fz: f32) -> f32 {
    let g = GRAD3[(hash(seed, ix, iy, iz) % 12) as usize];
    g[0] * fx + g[1] * fy + g[2] * fz
}

// One octave of 3D Perlin gradient noise, scaled to ~[-1, 1].
fn perlin3(seed: i32, x: f32, y: f32, z: f32) -> f32 {
    let ix = x.floor() as i32;
    let iy = y.floor() as i32;
    let iz = z.floor() as i32;
    let fx = x - ix as f32;
    let fy = y - iy as f32;
    let fz = z - iz as f32;
    let u = fade(fx);
    let v = fade(fy);
    let w = fade(fz);

    let n000 = grad_dot(seed, ix, iy, iz, fx, fy, fz);
    let n100 = grad_dot(seed, ix + 1, iy, iz, fx - 1.0, fy, fz);
    let n010 = grad_dot(seed, ix, iy + 1, iz, fx, fy - 1.0, fz);
    let n110 = grad_dot(seed, ix + 1, iy + 1, iz, fx - 1.0, fy - 1.0, fz);
    let n001 = grad_dot(seed, ix, iy, iz + 1, fx, fy, fz - 1.0);
    let n101 = grad_dot(seed, ix + 1, iy, iz + 1, fx - 1.0, fy, fz - 1.0);
    let n011 = grad_dot(seed, ix, iy + 1, iz + 1, fx, fy - 1.0, fz - 1.0);
    let n111 = grad_dot(seed, ix + 1, iy + 1, iz + 1, fx - 1.0, fy - 1.0, fz - 1.0);

    let nx00 = lerp(n000, n100, u);
    let nx10 = lerp(n010, n110, u);
    let nx01 = lerp(n001, n101, u);
    let nx11 = lerp(n011, n111, u);
    let nxy0 = lerp(nx00, nx10, v);
    let nxy1 = lerp(nx01, nx11, v);
    // 3D Perlin peaks around ±0.866; scale to fill ~[-1, 1].
    lerp(nxy0, nxy1, w) * 1.1547
}

impl Noise {
    pub fn new(seed: i32, freq: f32, octaves: i32, lacunarity: f32, gain: f32, fractal: Fractal) -> Self {
        let mut amp = 1.0_f32;
        let mut sum = 0.0_f32;
        for _ in 0..octaves.max(1) {
            sum += amp;
            amp *= gain;
        }
        let bounding = if sum > 0.0 { 1.0 / sum } else { 1.0 };
        Self { seed, freq, octaves: octaves.max(1), lacunarity, gain, fractal, bounding }
    }

    /// Ridged MULTIFRACTAL (Musgrave): like ridged fBm, but each octave is multiplied
    /// by the clamped signal of the PREVIOUS octave, so high-frequency detail
    /// concentrates on the crests and fades out in the valleys. The result is sharp,
    /// connected ridgelines with smooth troughs — real mountain structure, instead of
    /// the round bumps a single ridged term gives. Returns ~[0, 1] (1 at a crest);
    /// uses the configured freq/octaves/lacunarity/gain.
    pub fn ridged_multi_3d(&self, x: f32, y: f32, z: f32) -> f32 {
        const OFFSET: f32 = 1.0;
        const WEIGHT_GAIN: f32 = 2.0; // how strongly a crest amplifies the next octave
        let mut px = x * self.freq;
        let mut py = y * self.freq;
        let mut pz = z * self.freq;
        let mut amp = 1.0_f32;
        let mut weight = 1.0_f32;
        let mut sum = 0.0_f32;
        let mut norm = 0.0_f32;
        for _ in 0..self.octaves {
            let n = perlin3(self.seed, px, py, pz);
            let mut signal = (OFFSET - n.abs()).max(0.0);
            signal *= signal; // square → sharpen the ridge
            signal *= weight; // gate by the previous octave (kills valley detail)
            weight = (signal * WEIGHT_GAIN).clamp(0.0, 1.0);
            sum += signal * amp;
            norm += amp;
            amp *= self.gain;
            px *= self.lacunarity;
            py *= self.lacunarity;
            pz *= self.lacunarity;
        }
        if norm > 0.0 { (sum / norm).clamp(0.0, 1.0) } else { 0.0 }
    }

    pub fn get_noise_3d(&self, x: f32, y: f32, z: f32) -> f32 {
        let mut px = x * self.freq;
        let mut py = y * self.freq;
        let mut pz = z * self.freq;
        let mut amp = 1.0_f32;
        let mut sum = 0.0_f32;
        match self.fractal {
            Fractal::Fbm => {
                for _ in 0..self.octaves {
                    sum += perlin3(self.seed, px, py, pz) * amp;
                    px *= self.lacunarity;
                    py *= self.lacunarity;
                    pz *= self.lacunarity;
                    amp *= self.gain;
                }
                sum * self.bounding
            }
            Fractal::Ridged => {
                // Ridges peak where the underlying noise crosses zero.
                for _ in 0..self.octaves {
                    let n = perlin3(self.seed, px, py, pz);
                    sum += (1.0 - n.abs()) * 2.0 * amp;
                    px *= self.lacunarity;
                    py *= self.lacunarity;
                    pz *= self.lacunarity;
                    amp *= self.gain;
                }
                sum * self.bounding - 1.0
            }
        }
    }
}
