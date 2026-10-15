use std::env;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

use any_tts::{load_model, ModelType, SynthesisRequest, TtsConfig};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const PROTOCOL: i32 = 1;
const VOICE: &str = "bf_isabella";
const SAMPLE_RATE: u32 = 24000;
const MAX_LINE: usize = 8192;

#[derive(Debug, Deserialize)]
struct Request {
    protocol: i32,
    #[serde(rename = "type")]
    kind: String,
    id: Option<String>,
    turn: Option<String>,
    text: Option<String>,
}

#[derive(Debug, Serialize)]
struct HelloEvent<'a> {
    protocol: i32,
    event: &'a str,
    engine: &'a str,
    voice: &'a str,
    sample_rate: u32,
    offline: bool,
}

#[derive(Debug, Serialize)]
struct AudioEvent<'a> {
    protocol: i32,
    event: &'a str,
    id: &'a str,
    turn: &'a str,
    file: &'a str,
    samples: usize,
    sample_rate: u32,
}

#[derive(Debug, Serialize)]
struct CancelledEvent<'a> {
    protocol: i32,
    event: &'a str,
}

#[derive(Debug, Serialize)]
struct ErrorEvent<'a> {
    protocol: i32,
    event: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    turn: Option<&'a str>,
    code: &'a str,
}

struct Job {
    id: String,
    turn: String,
    text: String,
    epoch: usize,
}

fn emit_json<T: Serialize>(val: &T) {
    if let Ok(json) = serde_json::to_string(val) {
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        let _ = writeln!(handle, "{}", json);
        let _ = handle.flush();
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    let mut root_dir: Option<PathBuf> = None;
    let mut output_dir: Option<PathBuf> = None;

    let mut i = 1;
    while i < args.len() {
        if args[i] == "--root" && i + 1 < args.len() {
            root_dir = Some(PathBuf::from(&args[i + 1]));
            i += 2;
        } else if args[i] == "--output" && i + 1 < args.len() {
            output_dir = Some(PathBuf::from(&args[i + 1]));
            i += 2;
        } else {
            i += 1;
        }
    }

    let root = match root_dir {
        Some(r) => r,
        None => {
            emit_json(&ErrorEvent {
                protocol: PROTOCOL,
                event: "unavailable",
                id: None,
                turn: None,
                code: "missing_root_argument",
            });
            std::process::exit(2);
        }
    };

    let output = match output_dir {
        Some(o) => o,
        None => {
            emit_json(&ErrorEvent {
                protocol: PROTOCOL,
                event: "unavailable",
                id: None,
                turn: None,
                code: "missing_output_argument",
            });
            std::process::exit(2);
        }
    };

    let model_path = root.join("model");
    let model_dir = if model_path.exists() {
        model_path
    } else {
        root.clone()
    };

    let config = TtsConfig::new(ModelType::Kokoro).with_model_path(model_dir.to_string_lossy().to_string());
    let model = match load_model(config) {
        Ok(m) => Arc::new(m),
        Err(e) => {
            eprintln!("Failed to load Kokoro model from {}: {}", model_dir.display(), e);
            emit_json(&ErrorEvent {
                protocol: PROTOCOL,
                event: "unavailable",
                id: None,
                turn: None,
                code: "local_voice_setup_failed",
            });
            std::process::exit(2);
        }
    };

    let current_epoch = Arc::new(AtomicUsize::new(0));
    let (job_tx, job_rx) = mpsc::sync_channel::<Job>(24);
    let job_rx = Arc::new(Mutex::new(job_rx));

    // Spawn synthesis worker thread
    let worker_model = Arc::clone(&model);
    let worker_epoch = Arc::clone(&current_epoch);
    let worker_output = output.clone();

    thread::spawn(move || {
        while let Ok(job) = job_rx.lock().unwrap().recv() {
            if job.epoch != worker_epoch.load(Ordering::SeqCst) {
                continue;
            }

            let req = SynthesisRequest::new(&job.text).with_voice(VOICE);
            match worker_model.synthesize(&req) {
                Ok(audio) => {
                    if job.epoch != worker_epoch.load(Ordering::SeqCst) {
                        continue;
                    }
                    let filename = format!("audio-{}.wav", Uuid::new_v4());
                    let file_path = worker_output.join(&filename);
                    if let Err(e) = audio.save_wav(&file_path) {
                        eprintln!("Failed to save audio wav: {}", e);
                        emit_json(&ErrorEvent {
                            protocol: PROTOCOL,
                            event: "error",
                            id: Some(&job.id),
                            turn: Some(&job.turn),
                            code: "write_wav_failed",
                        });
                        continue;
                    }

                    emit_json(&AudioEvent {
                        protocol: PROTOCOL,
                        event: "audio",
                        id: &job.id,
                        turn: &job.turn,
                        file: &filename,
                        samples: audio.samples.len(),
                        sample_rate: SAMPLE_RATE,
                    });
                }
                Err(e) => {
                    eprintln!("Synthesis error: {}", e);
                    emit_json(&ErrorEvent {
                        protocol: PROTOCOL,
                        event: "error",
                        id: Some(&job.id),
                        turn: Some(&job.turn),
                        code: "synthesis_failed",
                    });
                }
            }
        }
    });

    // Announce hello
    emit_json(&HelloEvent {
        protocol: PROTOCOL,
        event: "hello",
        engine: "kokoro",
        voice: VOICE,
        sample_rate: SAMPLE_RATE,
        offline: true,
    });

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        if line.len() > MAX_LINE || line.trim().is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(_) => {
                emit_json(&ErrorEvent {
                    protocol: PROTOCOL,
                    event: "unavailable",
                    id: None,
                    turn: None,
                    code: "invalid_protocol_request",
                });
                break;
            }
        };

        if req.protocol != PROTOCOL {
            emit_json(&ErrorEvent {
                protocol: PROTOCOL,
                event: "unavailable",
                id: None,
                turn: None,
                code: "unsupported_protocol",
            });
            break;
        }

        match req.kind.as_str() {
            "shutdown" => {
                break;
            }
            "cancel" => {
                current_epoch.fetch_add(1, Ordering::SeqCst);
                emit_json(&CancelledEvent {
                    protocol: PROTOCOL,
                    event: "cancelled",
                });
            }
            "speak" => {
                let id = req.id.unwrap_or_default();
                let turn = req.turn.unwrap_or_default();
                let text = req.text.unwrap_or_default();

                let epoch = current_epoch.load(Ordering::SeqCst);
                let job = Job { id: id.clone(), turn: turn.clone(), text, epoch };

                if let Err(_) = job_tx.try_send(job) {
                    emit_json(&ErrorEvent {
                        protocol: PROTOCOL,
                        event: "error",
                        id: Some(&id),
                        turn: Some(&turn),
                        code: "queue_full",
                    });
                }
            }
            _ => {
                emit_json(&ErrorEvent {
                    protocol: PROTOCOL,
                    event: "error",
                    id: req.id.as_deref(),
                    turn: req.turn.as_deref(),
                    code: "unsupported_request",
                });
            }
        }
    }

    Ok(())
}
