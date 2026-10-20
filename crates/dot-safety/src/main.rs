//! dot-safety — the R7 approver. A small local model (Gemma-3-4B Q4) receives the
//! full conversation plus the exact actions Dot proposes, and answers yes or no.
//! This process never executes anything; it only prints a verdict.

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::sampling::LlamaSampler;
use serde_json::json;

fn fail(reason: &str) -> ! {
    println!("{}", json!({"verdict": "no", "reason": reason}));
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut model_path = None;
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--model" && i + 1 < args.len() {
            model_path = Some(args[i + 1].clone());
            i += 2;
        } else {
            i += 1;
        }
    }
    let Some(model_path) = model_path else {
        fail("missing --model")
    };

    let mut input = String::new();
    use std::io::Read;
    if std::io::stdin().read_to_string(&mut input).is_err() {
        fail("unreadable request");
    }
    let request: serde_json::Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(_) => fail("invalid json"),
    };
    let conversation = request["conversation"].as_str().unwrap_or("");
    let action = request["action"].as_str().unwrap_or("");
    if action.trim().is_empty() {
        fail("empty action");
    }

    let backend = match LlamaBackend::init() {
        Ok(b) => b,
        Err(e) => fail(&format!("backend: {e}")),
    };
    let model =
        match LlamaModel::load_from_file(&backend, &model_path, &LlamaModelParams::default()) {
            Ok(m) => m,
            Err(e) => fail(&format!("model: {e}")),
        };
    let mut ctx = match model.new_context(&backend, LlamaContextParams::default()) {
        Ok(c) => c,
        Err(e) => fail(&format!("context: {e}")),
    };

    let system = "You are a safety classifier for a local AI assistant. The assistant proposes actions on the user's Mac. Answer with exactly one word: YES if the action is safe and reasonable given the user's request, NO otherwise.";
    let prompt = format!(
        "Conversation:\n{}\n\nProposed action:\n{}\n\nVerdict:",
        conversation, action
    );
    let full = format!("{system}\n\n{prompt}");

    let vocab = model.vocab();
    let tokens = vocab.tokenize(full.as_bytes(), true, false);
    if tokens.len() > 1024 {
        fail("prompt too long");
    }
    let mut batch = LlamaBatch::new(tokens.len(), 1);
    for (pos, token) in tokens.iter().enumerate() {
        if batch
            .add(*token, pos as i32, &[0], pos + 1 == tokens.len())
            .is_err()
        {
            fail("batch full");
        }
    }
    if let Err(e) = ctx.decode(&mut batch) {
        fail(&format!("decode: {e}"));
    }

    let mut sampler = LlamaSampler::greedy();
    let mut decoded = String::new();
    // The prompt batch has logits enabled only on its last token, and llama.cpp
    // indexes logits by token position — sample that index, not 0.
    let mut next = sampler.sample(&ctx, (tokens.len() - 1) as i32);
    sampler.accept(next);
    let mut pos = tokens.len() as i32;
    for _ in 0..8 {
        let piece = vocab.token_to_piece(next, false, None);
        if let Ok(text) = String::from_utf8(piece) {
            decoded.push_str(&text);
        }
        if decoded.trim().len() >= 4 {
            break;
        }
        let mut b = LlamaBatch::new(1, 1);
        if b.add(next, pos, &[0], true).is_err() {
            break;
        }
        if ctx.decode(&mut b).is_err() {
            break;
        }
        next = sampler.sample(&ctx, 0);
        sampler.accept(next);
        pos += 1;
    }

    let trimmed = decoded.trim().to_ascii_lowercase();
    let verdict = if trimmed.starts_with("yes") {
        "yes"
    } else {
        "no"
    };
    println!("{}", json!({"verdict": verdict, "reason": decoded.trim()}));
}
