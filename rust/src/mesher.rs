//! Hand-rolled marching-cubes mesher with crack-free LOD seams via Transvoxel
//! transition cells. No external mesher crate. Operates on a density grid sampled
//! from `PlanetDensity`; `coarser_mask` marks faces whose neighbour is COARSER.
//! On those faces the regular MC boundary is carved inward by a slab and the slab
//! is filled with transition cells whose low-res face matches the coarse
//! neighbour exactly and whose high-res face matches the carved regular mesh.
//! Returns flat position/normal arrays and triangle indices.

use crate::density::PlanetDensity;
use crate::tables;

#[derive(Clone, Copy)]
struct V3 {
    x: f32,
    y: f32,
    z: f32,
}
impl V3 {
    #[inline] fn new(x: f32, y: f32, z: f32) -> Self { Self { x, y, z } }
    #[inline] fn add(self, o: V3) -> V3 { V3::new(self.x + o.x, self.y + o.y, self.z + o.z) }
    #[inline] fn sub(self, o: V3) -> V3 { V3::new(self.x - o.x, self.y - o.y, self.z - o.z) }
    #[inline] fn muls(self, s: f32) -> V3 { V3::new(self.x * s, self.y * s, self.z * s) }
    #[inline] fn lerp(self, o: V3, t: f32) -> V3 { self.add(o.sub(self).muls(t)) }
    #[inline] fn dot(self, o: V3) -> f32 { self.x * o.x + self.y * o.y + self.z * o.z }
    #[inline] fn len_sq(self) -> f32 { self.dot(self) }
    #[inline] fn normalized(self) -> V3 {
        let l = self.len_sq().sqrt();
        if l > 1e-12 { self.muls(1.0 / l) } else { self }
    }
}

// Edge → owning-corner + axis mapping for the per-axis edge vertex cache.
const E_AXIS: [usize; 12] = [0, 2, 0, 2, 0, 2, 0, 2, 1, 1, 1, 1];
const E_DCI: [usize; 12] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0];
const E_DCJ: [usize; 12] = [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0];
const E_DCK: [usize; 12] = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1];

// Transition cells were emitted double-sided as a safety net while their winding
// was unverified: a winding mistake can't make a double-sided face invisible, it
// just costs 2× transition triangles (a minority of the mesh). Set this to false
// to emit them single-sided (winding = Lengyel `flip_winding` XOR face side). If
// the transition surfaces then render inside-out, invert the parity in
// emit_transition_cell. Kept true by default until visually confirmed watertight.
const TRANSITION_DOUBLE_SIDED: bool = true;

pub struct MeshData {
    pub positions: Vec<f32>,
    pub normals: Vec<f32>,
    pub indices: Vec<i32>,
    /// De-indexed triangle soup (flat x,y,z per vertex) for ConcavePolygonShape3D.
    /// Empty unless `want_collision` was set — only near chunks need it, and
    /// building it here keeps it off the main thread.
    pub collision_faces: Vec<f32>,
}

pub fn build(
    origin: [f32; 3],
    size: f32,
    resolution: usize,
    coarser_mask: i32,
    planet_center: [f32; 3],
    want_collision: bool,
    density: &PlanetDensity,
) -> MeshData {
    let origin = V3::new(origin[0], origin[1], origin[2]);
    let pc = V3::new(planet_center[0], planet_center[1], planet_center[2]);
    let voxel = size / resolution as f32;
    let gs = resolution + 3;
    let gs2 = gs * gs;
    let base = origin.sub(V3::new(voxel, voxel, voxel));

    // ── 1. Sample density grid (R+3)^3 (incl. 1-voxel halo) ─────────────────
    let mut d = vec![0.0f32; gs * gs * gs];
    for zi in 0..gs {
        let zw = base.z + zi as f32 * voxel;
        for yi in 0..gs {
            let yw = base.y + yi as f32 * voxel;
            for xi in 0..gs {
                let xw = base.x + xi as f32 * voxel;
                d[xi + yi * gs + zi * gs2] = density.sample(xw, yw, zw);
            }
        }
    }

    // (LOD seams are sealed by Transvoxel transition cells after the MC pass,
    // not by boundary resampling.)

    if !has_surface(&d) {
        return MeshData {
            positions: vec![], normals: vec![], indices: vec![], collision_faces: vec![],
        };
    }

    // ── 2. Per-corner gradients on the (R+1)^3 corner grid ──────────────────
    let cs = resolution + 1;
    let cs2 = cs * cs;
    let mut grad = vec![V3::new(0.0, 0.0, 0.0); cs * cs * cs];
    for ck in 0..cs {
        let ka = ck + 1;
        for cj in 0..cs {
            let ja = cj + 1;
            for ci in 0..cs {
                let ia = ci + 1;
                let off = ci + cj * cs + ck * cs2;
                let gx = d[(ia + 1) + ja * gs + ka * gs2] - d[(ia - 1) + ja * gs + ka * gs2];
                let gy = d[ia + (ja + 1) * gs + ka * gs2] - d[ia + (ja - 1) * gs + ka * gs2];
                let gz = d[ia + ja * gs + (ka + 1) * gs2] - d[ia + ja * gs + (ka - 1) * gs2];
                grad[off] = V3::new(gx, gy, gz);
            }
        }
    }

    let mut positions: Vec<V3> = Vec::new();
    let mut normals: Vec<V3> = Vec::new();
    let mut indices: Vec<i32> = Vec::new();

    // ── 3. Marching cubes with per-axis edge caches ─────────────────────────
    let mut cx = vec![-1i32; resolution * cs * cs];
    let mut cy = vec![-1i32; cs * resolution * cs];
    let mut cz = vec![-1i32; cs * cs * resolution];
    let mut dv = [0.0f32; 8];
    let mut edge_verts = [0i32; 12];

    for ck in 0..resolution {
        for cj in 0..resolution {
            for ci in 0..resolution {
                let mut case_idx = 0usize;
                for corner in 0..8 {
                    let ai = ci + tables::CO_X[corner] as usize + 1;
                    let aj = cj + tables::CO_Y[corner] as usize + 1;
                    let ak = ck + tables::CO_Z[corner] as usize + 1;
                    let val = d[ai + aj * gs + ak * gs2];
                    dv[corner] = val;
                    if val > 0.0 {
                        case_idx |= 1 << corner;
                    }
                }
                let edges_mask = tables::EDGE_TABLE[case_idx];
                if edges_mask == 0 {
                    continue;
                }
                for e in 0..12 {
                    if (edges_mask & (1 << e)) == 0 {
                        continue;
                    }
                    let axis = E_AXIS[e];
                    let sci = ci + E_DCI[e];
                    let scj = cj + E_DCJ[e];
                    let sck = ck + E_DCK[e];
                    let cidx = match axis {
                        0 => sci + resolution * scj + resolution * cs * sck,
                        1 => sci + cs * scj + cs * resolution * sck,
                        _ => sci + cs * scj + cs2 * sck,
                    };
                    let cached = match axis {
                        0 => cx[cidx],
                        1 => cy[cidx],
                        _ => cz[cidx],
                    };
                    let v = if cached < 0 {
                        let nv = emit_edge_vertex(e, &dv, ci, cj, ck, voxel, base, &grad, cs, cs2,
                                                  &mut positions, &mut normals);
                        match axis {
                            0 => cx[cidx] = nv,
                            1 => cy[cidx] = nv,
                            _ => cz[cidx] = nv,
                        }
                        nv
                    } else {
                        cached
                    };
                    edge_verts[e] = v;
                }
                // Winding flip: Bourke table authored for opposite inside test.
                let tri_base = case_idx * 16;
                let mut ti = 0;
                while ti < 16 && tables::TRI_TABLE[tri_base + ti] >= 0 {
                    indices.push(edge_verts[tables::TRI_TABLE[tri_base + ti] as usize]);
                    indices.push(edge_verts[tables::TRI_TABLE[tri_base + ti + 2] as usize]);
                    indices.push(edge_verts[tables::TRI_TABLE[tri_base + ti + 1] as usize]);
                    ti += 3;
                }
            }
        }
    }

    // ── 3b. Transvoxel transition cells ─────────────────────────────────────
    // Carve the regular boundary inward by the slab depth and fill the slab with
    // transition cells: low-res face matches the coarse neighbour exactly (same
    // coarse corners), high-res face matches the carved regular mesh. Exact, no
    // bilinear residual. Emitted double-sided so a winding mistake can't leave
    // an invisible (back-faced) gap.
    if coarser_mask != 0 {
        shift_regular_boundary_vertices(&mut positions, origin, size, voxel, coarser_mask);
        build_transition_cells(&d, gs, gs2, resolution, voxel, origin, coarser_mask,
                               &grad, cs, cs2, density, &mut positions, &mut normals, &mut indices);
    }

    // ── Finalise normals (stored as raw +gradient; outward = -grad) ─────────
    let mut out_pos = Vec::with_capacity(positions.len() * 3);
    let mut out_nrm = Vec::with_capacity(normals.len() * 3);
    for i in 0..positions.len() {
        let p = positions[i];
        let mut radial = p.sub(pc);
        if radial.len_sq() < 1e-12 {
            radial = V3::new(0.0, 1.0, 0.0);
        }
        radial = radial.normalized();
        let mut n = normals[i].muls(-1.0);
        if n.len_sq() < 1e-12 {
            n = radial;
        } else {
            n = n.normalized();
            if n.dot(radial) < 0.0 {
                n = n.muls(-1.0);
            }
        }
        out_pos.push(p.x); out_pos.push(p.y); out_pos.push(p.z);
        out_nrm.push(n.x); out_nrm.push(n.y); out_nrm.push(n.z);
    }

    // De-index into a triangle soup for collision, only when asked (near chunks).
    let collision_faces = if want_collision {
        let mut cf = Vec::with_capacity(indices.len() * 3);
        for &idx in &indices {
            let i = idx as usize;
            cf.push(out_pos[3 * i]);
            cf.push(out_pos[3 * i + 1]);
            cf.push(out_pos[3 * i + 2]);
        }
        cf
    } else {
        Vec::new()
    };

    MeshData { positions: out_pos, normals: out_nrm, indices, collision_faces }
}

fn has_surface(d: &[f32]) -> bool {
    if d.is_empty() {
        return false;
    }
    let first = d[0] > 0.0;
    d.iter().any(|&v| (v > 0.0) != first)
}

fn emit_edge_vertex(
    e: usize, dv: &[f32; 8], ci: usize, cj: usize, ck: usize, voxel: f32, base: V3,
    grad: &[V3], cs: usize, cs2: usize,
    positions: &mut Vec<V3>, normals: &mut Vec<V3>,
) -> i32 {
    let ca = tables::EDGE_A[e] as usize;
    let cb = tables::EDGE_B[e] as usize;
    let da = dv[ca];
    let db = dv[cb];
    let denom = da - db;
    let t = if denom.abs() < 1e-8 { 0.5 } else { (da / denom).clamp(0.0, 1.0) };
    let pa = base.add(V3::new(
        (ci + tables::CO_X[ca] as usize + 1) as f32 * voxel,
        (cj + tables::CO_Y[ca] as usize + 1) as f32 * voxel,
        (ck + tables::CO_Z[ca] as usize + 1) as f32 * voxel,
    ));
    let pb = base.add(V3::new(
        (ci + tables::CO_X[cb] as usize + 1) as f32 * voxel,
        (cj + tables::CO_Y[cb] as usize + 1) as f32 * voxel,
        (ck + tables::CO_Z[cb] as usize + 1) as f32 * voxel,
    ));
    let p = pa.lerp(pb, t);
    let ga = (ci + tables::CO_X[ca] as usize) + cs * (cj + tables::CO_Y[ca] as usize)
        + cs2 * (ck + tables::CO_Z[ca] as usize);
    let gb = (ci + tables::CO_X[cb] as usize) + cs * (cj + tables::CO_Y[cb] as usize)
        + cs2 * (ck + tables::CO_Z[cb] as usize);
    let n = grad[ga].lerp(grad[gb], t);
    positions.push(p);
    normals.push(n);
    (positions.len() - 1) as i32
}

// Shift regular-mesh vertices that sit exactly on a coarser-LOD face inward by
// the slab depth, opening the slab the transition cells fill.
fn shift_regular_boundary_vertices(
    positions: &mut [V3], origin: V3, size: f32, voxel: f32, coarser_mask: i32,
) {
    let amount = (0.5 * voxel).min(1.5);
    let eps = voxel * 0.01;
    let (min_x, max_x) = (origin.x, origin.x + size);
    let (min_y, max_y) = (origin.y, origin.y + size);
    let (min_z, max_z) = (origin.z, origin.z + size);
    for p in positions.iter_mut() {
        if (coarser_mask & 1) != 0 && (p.x - min_x).abs() < eps { p.x += amount; }
        if (coarser_mask & 2) != 0 && (p.x - max_x).abs() < eps { p.x -= amount; }
        if (coarser_mask & 4) != 0 && (p.y - min_y).abs() < eps { p.y += amount; }
        if (coarser_mask & 8) != 0 && (p.y - max_y).abs() < eps { p.y -= amount; }
        if (coarser_mask & 16) != 0 && (p.z - min_z).abs() < eps { p.z += amount; }
        if (coarser_mask & 32) != 0 && (p.z - max_z).abs() < eps { p.z -= amount; }
    }
}

fn arr3_set(a: &mut [usize; 3], axis: usize, u_axis: usize, v_axis: usize, av: usize, uv: usize, vv: usize) {
    a[axis] = av;
    a[u_axis] = uv;
    a[v_axis] = vv;
}

fn face_sample_index(axis: usize, u_axis: usize, v_axis: usize, fixed_chunk: usize,
                     ci_u: usize, ci_v: usize, gs: usize, gs2: usize) -> usize {
    let mut a = [0usize; 3];
    arr3_set(&mut a, axis, u_axis, v_axis, fixed_chunk + 1, ci_u + 1, ci_v + 1);
    a[0] + a[1] * gs + a[2] * gs2
}

fn corner_world_pos(axis: usize, u_axis: usize, v_axis: usize, fixed_chunk: usize,
                    ci_u: usize, ci_v: usize, voxel: f32, origin: V3) -> V3 {
    let mut c = [0usize; 3];
    arr3_set(&mut c, axis, u_axis, v_axis, fixed_chunk, ci_u, ci_v);
    origin.add(V3::new(c[0] as f32 * voxel, c[1] as f32 * voxel, c[2] as f32 * voxel))
}

fn corner_gradient(axis: usize, u_axis: usize, v_axis: usize, fixed_chunk: usize,
                   ci_u: usize, ci_v: usize, grad: &[V3], cs: usize, cs2: usize) -> V3 {
    let mut c = [0usize; 3];
    arr3_set(&mut c, axis, u_axis, v_axis, fixed_chunk, ci_u, ci_v);
    grad[c[0] + c[1] * cs + c[2] * cs2]
}

// Raw +gradient at a world point via central differences at spacing h (the
// coarse neighbour's voxel), matching the coarse mesh's normal at the seam.
fn coarse_resolution_gradient(p: V3, density: &PlanetDensity, h: f32) -> V3 {
    let dx = density.sample(p.x + h, p.y, p.z) - density.sample(p.x - h, p.y, p.z);
    let dy = density.sample(p.x, p.y + h, p.z) - density.sample(p.x, p.y - h, p.z);
    let dz = density.sample(p.x, p.y, p.z + h) - density.sample(p.x, p.y, p.z - h);
    V3::new(dx, dy, dz)
}

fn build_transition_cells(
    d: &[f32], gs: usize, gs2: usize, resolution: usize, voxel: f32, origin: V3,
    coarser_mask: i32, grad: &[V3], cs: usize, cs2: usize, density: &PlanetDensity,
    positions: &mut Vec<V3>, normals: &mut Vec<V3>, indices: &mut Vec<i32>,
) {
    for face_bit in 0..6 {
        if (coarser_mask & (1 << face_bit)) == 0 {
            continue;
        }
        process_transition_face(face_bit, d, gs, gs2, resolution, voxel, origin,
                                grad, cs, cs2, density, positions, normals, indices);
    }
}

fn process_transition_face(
    face_bit: usize, d: &[f32], gs: usize, gs2: usize, resolution: usize, voxel: f32, origin: V3,
    grad: &[V3], cs: usize, cs2: usize, density: &PlanetDensity,
    positions: &mut Vec<V3>, normals: &mut Vec<V3>, indices: &mut Vec<i32>,
) {
    let axis = face_bit / 2;
    let side = face_bit & 1;
    let u_axis = (axis + 1) % 3;
    let v_axis = (axis + 2) % 3;
    let fixed_chunk = if side == 1 { resolution } else { 0 };
    let inward_sign = if side == 1 { -1.0 } else { 1.0 };
    let slab_depth = (0.5 * voxel).min(1.5);
    let mut inward_off = V3::new(0.0, 0.0, 0.0);
    match axis {
        0 => inward_off.x = inward_sign * slab_depth,
        1 => inward_off.y = inward_sign * slab_depth,
        _ => inward_off.z = inward_sign * slab_depth,
    }

    let mut fu = 0;
    while fu + 2 <= resolution {
        let mut fv = 0;
        while fv + 2 <= resolution {
            emit_transition_cell(axis, u_axis, v_axis, side, fixed_chunk, inward_off,
                                 fu, fv, d, gs, gs2, voxel, origin,
                                 grad, cs, cs2, density, positions, normals, indices);
            fv += 2;
        }
        fu += 2;
    }
}

fn emit_transition_cell(
    axis: usize, u_axis: usize, v_axis: usize, side: usize, fixed_chunk: usize, inward_off: V3,
    fu: usize, fv: usize,
    d: &[f32], gs: usize, gs2: usize, voxel: f32, origin: V3,
    grad: &[V3], cs: usize, cs2: usize, density: &PlanetDensity,
    positions: &mut Vec<V3>, normals: &mut Vec<V3>, indices: &mut Vec<i32>,
) {
    let mut samples = [0.0f32; 13];
    for sv in 0..3 {
        for su in 0..3 {
            samples[sv * 3 + su] =
                d[face_sample_index(axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv, gs, gs2)];
        }
    }
    samples[9] = samples[0];
    samples[10] = samples[2];
    samples[11] = samples[6];
    samples[12] = samples[8];

    let mut case_code = 0usize;
    if samples[0] < 0.0 { case_code |= 0x001; }
    if samples[1] < 0.0 { case_code |= 0x002; }
    if samples[2] < 0.0 { case_code |= 0x004; }
    if samples[5] < 0.0 { case_code |= 0x008; }
    if samples[8] < 0.0 { case_code |= 0x010; }
    if samples[7] < 0.0 { case_code |= 0x020; }
    if samples[6] < 0.0 { case_code |= 0x040; }
    if samples[3] < 0.0 { case_code |= 0x080; }
    if samples[4] < 0.0 { case_code |= 0x100; }
    if case_code == 0 || case_code == 511 {
        return;
    }

    let cell_class_raw = tables::CELL_CLASS[case_code];
    let cell_class = (cell_class_raw & 0x7f) as usize;
    let flip_winding = (cell_class_raw & 0x80) != 0;
    let geom = tables::CELL_GEOM[cell_class];
    let vertex_count = (geom >> 4) as usize;
    let triangle_count = (geom & 0x0f) as usize;
    let class_indices = tables::CELL_INDICES[cell_class];

    let mut cpos = [V3::new(0.0, 0.0, 0.0); 13];
    for sv in 0..3 {
        for su in 0..3 {
            let bp = corner_world_pos(axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv, voxel, origin);
            cpos[sv * 3 + su] = bp.add(inward_off);
        }
    }
    cpos[9] = corner_world_pos(axis, u_axis, v_axis, fixed_chunk, fu, fv, voxel, origin);
    cpos[10] = corner_world_pos(axis, u_axis, v_axis, fixed_chunk, fu + 2, fv, voxel, origin);
    cpos[11] = corner_world_pos(axis, u_axis, v_axis, fixed_chunk, fu, fv + 2, voxel, origin);
    cpos[12] = corner_world_pos(axis, u_axis, v_axis, fixed_chunk, fu + 2, fv + 2, voxel, origin);

    let mut cgrad = [V3::new(0.0, 0.0, 0.0); 13];
    for sv in 0..3 {
        for su in 0..3 {
            cgrad[sv * 3 + su] =
                corner_gradient(axis, u_axis, v_axis, fixed_chunk, fu + su, fv + sv, grad, cs, cs2);
        }
    }
    let coarse_h = 2.0 * voxel;
    cgrad[9] = coarse_resolution_gradient(cpos[9], density, coarse_h);
    cgrad[10] = coarse_resolution_gradient(cpos[10], density, coarse_h);
    cgrad[11] = coarse_resolution_gradient(cpos[11], density, coarse_h);
    cgrad[12] = coarse_resolution_gradient(cpos[12], density, coarse_h);

    // Emit every vertex fresh (no reuse cache — no slot-indexing bugs).
    let mut local_verts = [0i32; 13];
    for vi in 0..vertex_count {
        let edge_code = tables::VERTEX_DATA[case_code * 12 + vi];
        let ca = ((edge_code >> 4) & 0x0f) as usize;
        let cb = (edge_code & 0x0f) as usize;
        let sa = samples[ca];
        let sb = samples[cb];
        let denom = sb - sa;
        let t = if denom.abs() < 1e-8 { 0.5 } else { (sb / denom).clamp(0.0, 1.0) };
        local_verts[vi] = emit_transition_vertex(t, ca, cb, &cpos, &cgrad, positions, normals);
    }

    // Single-sided winding = Lengyel `flip_winding` XOR the face side; the −/+
    // faces of the slab point opposite ways. Invert this `flip` if transition
    // surfaces render inside-out. Double-sided (default) ignores winding by
    // emitting both orders.
    let flip = flip_winding ^ (side == 1);
    for ti in 0..triangle_count {
        let i0 = local_verts[class_indices[ti * 3] as usize];
        let i1 = local_verts[class_indices[ti * 3 + 1] as usize];
        let i2 = local_verts[class_indices[ti * 3 + 2] as usize];
        if TRANSITION_DOUBLE_SIDED {
            indices.push(i0); indices.push(i1); indices.push(i2);
            indices.push(i0); indices.push(i2); indices.push(i1);
        } else if flip {
            indices.push(i0); indices.push(i2); indices.push(i1);
        } else {
            indices.push(i0); indices.push(i1); indices.push(i2);
        }
    }
}

fn emit_transition_vertex(
    t: f32, ca: usize, cb: usize, cpos: &[V3; 13], cgrad: &[V3; 13],
    positions: &mut Vec<V3>, normals: &mut Vec<V3>,
) -> i32 {
    let pa = cpos[ca];
    let pb = cpos[cb];
    let p = pa.muls(t).add(pb.muls(1.0 - t));
    let ga = cgrad[ca];
    let gb = cgrad[cb];
    let g = ga.muls(t).add(gb.muls(1.0 - t));
    positions.push(p);
    normals.push(g);
    (positions.len() - 1) as i32
}
