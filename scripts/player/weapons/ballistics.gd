class_name Ballistics
extends RefCounted

const G          := 9.80665
const BC_G7_TO_SI := 703.07
const GR_TO_KG   := 0.00006480
const MPS_TO_FPS := 3.28084
const J_TO_FTLB  := 0.737562

const CARTRIDGES := {
	"762_AK": {
		"name": "7.62x39mm AK-47",
		"mv_mps": 715.0,
		"mass_gr": 123.0,
		"bc_g7": 0.150,
		"diameter_in": 0.311,
		"twist_in": 9.45,
		"rh_twist": true,
		"mv_sd_mps": 4.0,
	},
	"9mm_Pistol": {
		"name": "9x19mm Parabellum",
		"mv_mps": 360.0,
		"mass_gr": 115.0,
		"bc_g7": 0.070,
		"diameter_in": 0.355,
		"twist_in": 10.0,
		"rh_twist": true,
		"mv_sd_mps": 3.0,
	}
}

const G7_TABLE: Array = [
	[0.000, 0.1198], [0.050, 0.1197], [0.100, 0.1196],
	[0.150, 0.1194], [0.200, 0.1193], [0.250, 0.1194],
	[0.300, 0.1194], [0.350, 0.1194], [0.400, 0.1193],
	[0.450, 0.1193], [0.500, 0.1194], [0.550, 0.1193],
	[0.600, 0.1194], [0.650, 0.1197], [0.700, 0.1202],
	[0.725, 0.1207], [0.750, 0.1215], [0.775, 0.1226],
	[0.800, 0.1242], [0.825, 0.1266], [0.850, 0.1306],
	[0.875, 0.1368], [0.900, 0.1464], [0.925, 0.1660],
	[0.950, 0.2054], [0.975, 0.2993], [1.000, 0.3803],
	[1.025, 0.4015], [1.050, 0.4043], [1.075, 0.4034],
	[1.100, 0.4014], [1.150, 0.3955], [1.200, 0.3884],
	[1.300, 0.3749], [1.400, 0.3605], [1.500, 0.3459],
	[1.600, 0.3316], [1.700, 0.3169], [1.800, 0.3021],
	[1.900, 0.2877], [2.000, 0.2732], [2.500, 0.2208],
	[3.000, 0.1935], [3.500, 0.1797], [4.000, 0.1739],
	[4.500, 0.1793], [5.000, 0.1876],
]

static func g7_cd(mach: float) -> float:
	mach = clampf(mach, 0.0, 5.0)
	for i in range(G7_TABLE.size() - 1):
		if mach <= G7_TABLE[i + 1][0]:
			var t: float = (mach - float(G7_TABLE[i][0])) / (float(G7_TABLE[i + 1][0]) - float(G7_TABLE[i][0]))
			return lerpf(float(G7_TABLE[i][1]), float(G7_TABLE[i + 1][1]), t)
	return float(G7_TABLE[-1][1])

static func air_density(altitude_m: float, temp_c: float, humidity: float = 0.5) -> float:
	var T  := temp_c + 273.15
	var P  := 101325.0 * pow(1.0 - 2.2558e-5 * altitude_m, 5.2559)
	var Psat := 611.21 * exp((18.678 - temp_c / 234.5) * (temp_c / (257.14 + temp_c)))
	var Pv   := humidity * Psat
	return (P - 0.378 * Pv) / (287.058 * T)

static func speed_of_sound(temp_c: float) -> float:
	return 331.3 * sqrt(1.0 + temp_c / 273.15)

static func drag_accel(vel_rel: Vector3, bc_g7: float, rho: float, temp_c: float = 15.0) -> Vector3:
	var speed := vel_rel.length()
	if speed < 0.5: return Vector3.ZERO
	var mach  := speed / speed_of_sound(temp_c)
	var cd    := g7_cd(mach)
	var bc_si := bc_g7 * BC_G7_TO_SI
	var decel := (rho * speed * speed * cd) / (2.0 * bc_si)
	return -vel_rel.normalized() * decel

# gravity is a full vector so callers on a planet can point it radially
# (default = flat-world -Y, the original reference behavior).
static func eom(_pos: Vector3, vel: Vector3, _tof: float, bc_g7: float, wind: Vector3, rho: float, temp_c: float, gravity: Vector3 = Vector3(0.0, -G, 0.0)) -> Array:
	var a := Vector3.ZERO
	a += drag_accel(vel - wind, bc_g7, rho, temp_c)
	a += gravity
	return [vel, a]

static func rk4(pos: Vector3, vel: Vector3, tof: float, dt: float, bc_g7: float, wind: Vector3, rho: float, temp_c: float, gravity: Vector3 = Vector3(0.0, -G, 0.0)) -> Array:
	var k1 := eom(pos,               vel,               tof,         bc_g7, wind, rho, temp_c, gravity)
	var k2 := eom(pos+k1[0]*dt*0.5, vel+k1[1]*dt*0.5, tof+dt*0.5, bc_g7, wind, rho, temp_c, gravity)
	var k3 := eom(pos+k2[0]*dt*0.5, vel+k2[1]*dt*0.5, tof+dt*0.5, bc_g7, wind, rho, temp_c, gravity)
	var k4 := eom(pos+k3[0]*dt,     vel+k3[1]*dt,     tof+dt,     bc_g7, wind, rho, temp_c, gravity)
	return [
		pos + (k1[0] + 2.0*k2[0] + 2.0*k3[0] + k4[0]) * (dt/6.0),
		vel + (k1[1] + 2.0*k2[1] + 2.0*k3[1] + k4[1]) * (dt/6.0),
	]
