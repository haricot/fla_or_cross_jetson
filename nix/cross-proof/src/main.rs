fn main() {
    // No CUDA driver, Jetson device, or target runtime required for this build gate.
    println!("arch={} os={}", std::env::consts::ARCH, std::env::consts::OS);
}

#[cfg(test)]
mod tests {
    #[test]
    fn embedded_build_target_is_aarch64() {
        assert!(cfg!(target_arch = "aarch64"));
        assert!(cfg!(target_os = "linux"));
    }
}
