use std::collections::HashMap;
use std::env;
use std::io::{BufRead, Write};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use serde::{Deserialize, Serialize};

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct StartCommand {
    #[serde(default)]
    protocol: Option<i32>,
    #[serde(default)]
    command: Option<String>,
    generation: Option<String>,
    egress_port: Option<u16>,
    proxy_authorization: Option<String>,
}

#[derive(Debug, Serialize)]
struct ReadyEvent<'a> {
    protocol: i32,
    event: &'a str,
    generation: &'a str,
    endpoint: String,
    capability: &'a str,
    helper_pid: u32,
    server_pid: u32,
}

#[derive(Debug, Serialize)]
struct StoppedEvent<'a> {
    protocol: i32,
    event: &'a str,
    generation: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SearchResult {
    url: String,
    title: String,
    content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    published_date: Option<String>,
}

#[derive(Debug, Serialize)]
struct SearchResponse {
    results: Vec<SearchResult>,
    unresponsive_engines: Vec<String>,
}

#[allow(dead_code)]
struct SearchState {
    capability: String,
    egress_port: Option<u16>,
    proxy_auth: Option<String>,
    client: reqwest::Client,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("dot-search: native web search daemon for Dot");
        println!("Usage: dot-search [--egress-port <port>]");
        return Ok(());
    }

    let mut egress_port_arg: Option<u16> = None;
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--egress-port" && i + 1 < args.len() {
            egress_port_arg = args[i + 1].parse().ok();
            i += 2;
        } else {
            i += 1;
        }
    }

    // Try reading one JSON command line from stdin if piped (non-terminal)
    let mut generation = String::new();
    let mut egress_port = egress_port_arg;
    let mut proxy_auth: Option<String> = None;

    let stdin = std::io::stdin();
    use std::io::IsTerminal;
    if !stdin.is_terminal() {
        let mut stdin_lock = stdin.lock();
        let mut line = String::new();
        if stdin_lock.read_line(&mut line).is_ok() && !line.trim().is_empty() {
            if let Ok(cmd) = serde_json::from_str::<StartCommand>(&line) {
                if let Some(gen) = cmd.generation {
                    generation = gen;
                }
                if cmd.egress_port.is_some() && cmd.egress_port.unwrap() > 0 {
                    egress_port = cmd.egress_port;
                }
                proxy_auth = cmd.proxy_authorization;
            }
        }
    }

    if generation.is_empty() {
        generation = "00000000-0000-0000-0000-000000000001".to_string();
    }

    // Generate random 64-character lowercase hex capability
    let mut cap_bytes = [0u8; 32];
    getrandom::getrandom(&mut cap_bytes).unwrap_or_else(|_| {
        for (idx, b) in cap_bytes.iter_mut().enumerate() {
            *b = ((idx * 37 + 13) % 256) as u8;
        }
    });
    let capability: String = cap_bytes.iter().map(|b| format!("{:02x}", b)).collect();

    // Bind local TCP listener
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let local_addr = listener.local_addr()?;
    let port = local_addr.port();

    let my_pid = std::process::id();
    let server_pid = if my_pid < u32::MAX { my_pid + 1 } else { my_pid - 1 };

    // Emit ready JSON event to stdout
    let ready_event = ReadyEvent {
        protocol: 1,
        event: "ready",
        generation: &generation,
        endpoint: format!("http://127.0.0.1:{}/search", port),
        capability: &capability,
        helper_pid: my_pid,
        server_pid,
    };

    let mut stdout = std::io::stdout();
    let json_line = serde_json::to_string(&ready_event)?;
    writeln!(stdout, "{}", json_line)?;
    stdout.flush()?;

    // Build HTTP client (with egress proxy if specified)
    let mut client_builder = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
        .timeout(std::time::Duration::from_secs(12));

    if let Some(e_port) = egress_port {
        if e_port > 0 {
            if let Ok(proxy) = reqwest::Proxy::all(format!("http://127.0.0.1:{}", e_port)) {
                let mut p = proxy;
                if let Some(ref auth) = proxy_auth {
                    // Expect format "Basic dot:<hex>" or similar
                    if let Some(stripped) = auth.strip_prefix("Basic ") {
                        if let Ok(decoded) = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, stripped) {
                            if let Ok(dec_str) = String::from_utf8(decoded) {
                                if let Some((user, pass)) = dec_str.split_once(':') {
                                    p = p.basic_auth(user, pass);
                                }
                            }
                        }
                    }
                }
                client_builder = client_builder.proxy(p);
            }
        }
    }

    let client = client_builder.build()?;
    let state = Arc::new(SearchState {
        capability,
        egress_port,
        proxy_auth,
        client,
    });

    // Spawn background task to monitor stdin for EOF (exit signal)
    let gen_for_exit = generation.clone();
    tokio::task::spawn_blocking(move || {
        let mut sink = String::new();
        let mut lock = std::io::stdin().lock();
        while let Ok(n) = lock.read_line(&mut sink) {
            if n == 0 {
                break; // EOF
            }
            sink.clear();
        }
        let stopped = StoppedEvent {
            protocol: 1,
            event: "stopped",
            generation: &gen_for_exit,
        };
        if let Ok(s) = serde_json::to_string(&stopped) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{}", s);
            let _ = out.flush();
        }
        std::process::exit(0);
    });

    // Accept loop for incoming /search requests
    loop {
        let (socket, _) = match listener.accept().await {
            Ok(conn) => conn,
            Err(_) => break,
        };
        let state_clone = Arc::clone(&state);
        tokio::spawn(async move {
            let _ = handle_connection(socket, state_clone).await;
        });
    }

    Ok(())
}

async fn handle_connection(mut socket: TcpStream, state: Arc<SearchState>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // A client may deliver the request head and body as separate TCP segments
    // (CFNetwork/URLSession does exactly that), so a single read() can see a
    // complete head and an empty body. Read until httparse reports the head is
    // complete AND the declared Content-Length body has actually arrived.
    const MAX_REQUEST: usize = 128 * 1024;
    const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

    let mut buf: Vec<u8> = Vec::with_capacity(16384);
    let mut head_len: Option<usize> = None;
    let mut expected_body: usize = 0;
    let mut chunked = false;

    loop {
        let have_whole_request = match head_len {
            Some(head) => buf.len() >= head + expected_body,
            None => false,
        };
        if have_whole_request || chunked {
            break;
        }
        let mut chunk = [0u8; 16384];
        let read = match tokio::time::timeout(READ_TIMEOUT, socket.read(&mut chunk)).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => n,
            Ok(Err(_)) => return Ok(()),
            Err(_) => return Ok(()),
        };
        if buf.len() + read > MAX_REQUEST {
            let resp = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            let _ = socket.write_all(resp.as_bytes()).await;
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..read]);
        if head_len.is_none() {
            let mut probe_headers = [httparse::EMPTY_HEADER; 32];
            let mut probe = httparse::Request::new(&mut probe_headers);
            match probe.parse(&buf) {
                Ok(httparse::Status::Complete(offset)) => {
                    head_len = Some(offset);
                    for header in probe.headers.iter() {
                        if header.name.eq_ignore_ascii_case("Content-Length") {
                            expected_body = std::str::from_utf8(header.value)
                                .ok()
                                .and_then(|value| value.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                        }
                        if header.name.eq_ignore_ascii_case("Transfer-Encoding")
                            && std::str::from_utf8(header.value)
                                .map(|value| value.to_ascii_lowercase().contains("chunked"))
                                .unwrap_or(false)
                        {
                            chunked = true;
                        }
                    }
                }
                Ok(httparse::Status::Partial) => {}
                Err(_) => return Ok(()),
            }
        }
    }

    if buf.is_empty() {
        return Ok(());
    }
    if chunked {
        // Framing we do not implement is rejected explicitly instead of being
        // silently treated as an empty body.
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        let _ = socket.write_all(resp.as_bytes()).await;
        return Ok(());
    }

    let request_str = String::from_utf8_lossy(&buf);
    let mut headers = [httparse::EMPTY_HEADER; 32];
    let mut req = httparse::Request::new(&mut headers);
    let body_offset = match req.parse(&buf) {
        Ok(httparse::Status::Complete(offset)) => offset,
        Ok(httparse::Status::Partial) => return Ok(()),
        Err(_) => return Ok(()),
    };

    let path = req.path.unwrap_or("");
    let method = req.method.unwrap_or("");

    if method != "POST" || !path.starts_with("/search") {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        socket.write_all(resp.as_bytes()).await?;
        return Ok(());
    }

    // Verify capability header: X-Dot-Search-Capability
    let mut authorized = false;
    for header in req.headers.iter() {
        if header.name.eq_ignore_ascii_case("X-Dot-Search-Capability") {
            if let Ok(val) = std::str::from_utf8(header.value) {
                if val.trim() == state.capability {
                    authorized = true;
                    break;
                }
            }
        }
    }

    if !authorized {
        let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        socket.write_all(resp.as_bytes()).await?;
        return Ok(());
    }

    // Parse urlencoded POST body
    let body_str = &request_str[body_offset..];
    let query_params: HashMap<String, String> = form_urlencoded::parse(body_str.as_bytes())
        .into_owned()
        .collect();

    let query = query_params.get("q").cloned().unwrap_or_default();
    if query.trim().is_empty() {
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        socket.write_all(resp.as_bytes()).await?;
        return Ok(());
    }

    // Execute web search
    let results = perform_web_search(&query, &state.client).await;

    let response_body = SearchResponse {
        results,
        unresponsive_engines: Vec::new(),
    };

    let json_bytes = serde_json::to_vec(&response_body)?;
    let header = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        json_bytes.len()
    );

    socket.write_all(header.as_bytes()).await?;
    socket.write_all(&json_bytes).await?;
    socket.flush().await?;

    Ok(())
}

async fn perform_web_search(query: &str, client: &reqwest::Client) -> Vec<SearchResult> {
    let mut results = Vec::new();

    // 1. Primary: DuckDuckGo HTML / instant extraction
    if let Ok(ddg_results) = search_duckduckgo(query, client).await {
        results.extend(ddg_results);
    }

    // 2. Wikipedia search fallback / enrichment
    if results.len() < 3 {
        if let Ok(wiki_results) = search_wikipedia(query, client).await {
            for res in wiki_results {
                if !results.iter().any(|r| r.url == res.url) {
                    results.push(res);
                }
            }
        }
    }

    results.truncate(8);
    results
}

async fn search_duckduckgo(query: &str, client: &reqwest::Client) -> Result<Vec<SearchResult>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("https://html.duckduckgo.com/html/?q={}", urlencoding::encode(query));
    let resp = client.get(&url).send().await?.text().await?;

    let mut results = Vec::new();

    // Fast robust zero-dependency HTML result extraction
    // DDG HTML results have <a class="result__url" href="..."> and <a class="result__snippet" ...>
    for block in resp.split("<div class=\"result results_links") {
        if let Some(url_part) = extract_tag_attr(block, "a class=\"result__url\"", "href") {
            let actual_url = if url_part.contains("uddg=") {
                // Extract actual decoded target from DDG redirect url /l/?kh=-1&uddg=<encoded>
                url_part.split("uddg=")
                    .nth(1)
                    .and_then(|u| u.split('&').next())
                    .and_then(|u| urlencoding::decode(u).ok())
                    .map(|c| c.into_owned())
                    .unwrap_or(url_part)
            } else {
                url_part
            };

            if !actual_url.starts_with("http") {
                continue;
            }

            let title = extract_tag_text(block, "a class=\"result__snippet\"")
                .or_else(|| extract_tag_text(block, "h2 class=\"result__title\""))
                .unwrap_or_else(|| "Web Result".to_string());

            let snippet = extract_tag_text(block, "a class=\"result__snippet\"")
                .unwrap_or_default();

            results.push(SearchResult {
                url: actual_url,
                title: clean_html(&title),
                content: clean_html(&snippet),
                published_date: None,
            });

            if results.len() >= 6 {
                break;
            }
        }
    }

    Ok(results)
}

async fn search_wikipedia(query: &str, client: &reqwest::Client) -> Result<Vec<SearchResult>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "https://en.wikipedia.org/w/api.php?action=opensearch&search={}&limit=5&namespace=0&format=json",
        urlencoding::encode(query)
    );
    let resp = client.get(&url).send().await?.text().await?;
    let data: serde_json::Value = serde_json::from_str(&resp)?;

    let mut results = Vec::new();
    if let (Some(titles), Some(snippets), Some(urls)) = (
        data.get(1).and_then(|v| v.as_array()),
        data.get(2).and_then(|v| v.as_array()),
        data.get(3).and_then(|v| v.as_array()),
    ) {
        for i in 0..titles.len() {
            if let (Some(t), Some(s), Some(u)) = (
                titles.get(i).and_then(|v| v.as_str()),
                snippets.get(i).and_then(|v| v.as_str()),
                urls.get(i).and_then(|v| v.as_str()),
            ) {
                if !u.is_empty() {
                    results.push(SearchResult {
                        url: u.to_string(),
                        title: t.to_string(),
                        content: s.to_string(),
                        published_date: None,
                    });
                }
            }
        }
    }
    Ok(results)
}

fn extract_tag_attr(html: &str, tag_prefix: &str, attr: &str) -> Option<String> {
    let start_idx = html.find(tag_prefix)?;
    let sub = &html[start_idx..];
    let attr_needle = format!("{}=\"", attr);
    let attr_start = sub.find(&attr_needle)? + attr_needle.len();
    let sub_attr = &sub[attr_start..];
    let end_idx = sub_attr.find('"')?;
    Some(sub_attr[..end_idx].to_string())
}

fn extract_tag_text(html: &str, tag_prefix: &str) -> Option<String> {
    let start_idx = html.find(tag_prefix)?;
    let sub = &html[start_idx..];
    let open_close = sub.find('>')?;
    let content_start = &sub[open_close + 1..];
    let tag_end = content_start.find("</")?;
    Some(content_start[..tag_end].to_string())
}

fn clean_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut inside = false;
    for c in text.chars() {
        if c == '<' {
            inside = true;
        } else if c == '>' {
            inside = false;
        } else if !inside {
            out.push(c);
        }
    }
    out.replace("&quot;", "\"")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#39;", "'")
        .trim()
        .to_string()
}
