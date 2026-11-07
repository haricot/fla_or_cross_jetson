use jetson_secret_plane::{SecretResolver, SecretSpecResolver};
use secrecy::ExposeSecret;
use std::env;
use std::path::PathBuf;

#[derive(Debug)]
struct Opts {
    command: String,
    name: String,
    manifest: PathBuf,
    provider: String,
    profile: String,
    reason: String,
}

fn usage() -> ! {
    eprintln!(
        "usage: jetson-secret-resolver get|probe NAME [--manifest PATH] [--provider PROVIDER] [--profile PROFILE] [--reason TEXT]"
    );
    std::process::exit(2);
}

fn parse() -> Opts {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_else(|| usage());
    if command == "version" {
        println!("jetson-secret-resolver 0.1.0 (SecretSpec 0.20.0)");
        std::process::exit(0);
    }
    if command != "get" && command != "probe" {
        usage();
    }
    let name = args.next().unwrap_or_else(|| usage());
    let mut manifest = PathBuf::from("secretspec.toml");
    let mut provider = String::from("keyring");
    let mut profile = String::from("headless");
    let mut reason = String::from("jetson-secret-plane");
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--manifest" => manifest = PathBuf::from(args.next().unwrap_or_else(|| usage())),
            "--provider" => provider = args.next().unwrap_or_else(|| usage()),
            "--profile" => profile = args.next().unwrap_or_else(|| usage()),
            "--reason" => reason = args.next().unwrap_or_else(|| usage()),
            _ => usage(),
        }
    }
    Opts { command, name, manifest, provider, profile, reason }
}

fn main() {
    let opts = parse();
    let resolver = SecretSpecResolver::new(
        opts.manifest,
        opts.provider,
        opts.profile,
        opts.reason,
    );
    match resolver.resolve(&opts.name) {
        Ok(Some(value)) if opts.command == "get" => {
            // The only intentional exposure boundary. Callers redirect stdout
            // directly into a mode-0600 staging file; no log/status text shares
            // this stream.
            print!("{}", value.expose_secret());
        }
        Ok(Some(_)) => println!("PRESENT"),
        Ok(None) if opts.command == "probe" => {
            println!("MISSING");
            std::process::exit(3);
        }
        Ok(None) => {
            eprintln!("secret is missing");
            std::process::exit(3);
        }
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
