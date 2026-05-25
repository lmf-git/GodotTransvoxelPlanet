use godot::prelude::*;

struct TransvoxelNative;

#[gdextension]
unsafe impl ExtensionLibrary for TransvoxelNative {}

/// Native terrain generator. For now this is a build-feasibility scaffold
/// exposing a single `ping()` so we can confirm the GDExtension loads and is
/// callable from GDScript before porting the density field + mesher.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct NativeTerrain {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for NativeTerrain {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl NativeTerrain {
    /// Sanity check that the native lib is loaded and callable.
    #[func]
    fn ping(&self) -> i64 {
        42
    }
}
