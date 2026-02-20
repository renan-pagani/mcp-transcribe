# mcp-transcribe

MCP server para transcrever audio em tempo real usando Deepgram. Funciona como plugin do Claude Code — ao iniciar uma sessao, o servidor captura audio do sistema e transcreve via WebSocket.

## Como funciona

O servidor roda em **modo hibrido**: stdio para o protocolo MCP (como o Claude Code se comunica com ele) e um servidor HTTP em background na porta 8080 para receber audio via WebSocket.

```
Claude Code <--stdio--> MCP Server --websocket--> Deepgram
                            ^
                            |
              parec/audio --websocket--> :8080/audio/{sessionId}
```

### Tools disponiveis

| Tool | Descricao |
|------|-----------|
| `start_transcription` | Inicia uma sessao de transcricao. Retorna o `sessionId` e o `wsEndpoint` para enviar audio |
| `stop_transcription` | Para uma sessao ativa |
| `get_transcription` | Retorna os segmentos transcritos (paginado) |
| `get_session_status` | Status da sessao (ativa/parada, quantidade de segmentos) |
| `list_sessions` | Lista todas as sessoes (ativas e persistidas) |
| `export_session` | Exporta uma sessao em JSON, TXT ou SRT |

## Setup

### Pre-requisitos

- Swift 5.9+
- Conta no [Deepgram](https://deepgram.com) com API key
- `websocat` (para enviar audio via WebSocket): `cargo install websocat`
- PulseAudio/PipeWire (para capturar audio do sistema)

### Build

```bash
swift build
```

O binario fica em `.build/debug/App`.

### Configurar no Claude Code

Crie o arquivo `.mcp.json` na raiz do projeto:

```json
{
  "mcpServers": {
    "zelo-transcription": {
      "type": "stdio",
      "command": "/caminho/absoluto/para/.build/debug/App",
      "args": ["--stdio"],
      "env": {
        "DEEPGRAM_API_KEY": "sua-api-key-aqui"
      }
    }
  }
}
```

Inicie o Claude Code no diretorio do projeto. As 6 tools vao aparecer automaticamente.

## Uso

### 1. Iniciar transcricao

No Claude Code, use a tool `start_transcription`. Ela retorna um `sessionId` e um `wsEndpoint`.

### 2. Conectar audio

Em outro terminal, rode:

```bash
stdbuf -oL parec --format=s16le --rate=16000 --channels=1 \
  --device=alsa_output.pci-0000_00_1f.3.analog-stereo.monitor \
  --latency-msec=50 \
  | websocat -b ws://localhost:8080/audio/{SESSION_ID}
```

**Importante:**
- `websocat -b` (binary mode) e obrigatorio. Sem `-b`, o audio e enviado como text frames e corrompe os dados
- `stdbuf -oL` forca o flush do buffer do `parec`
- `--device=...monitor` captura o audio que sai do sistema (o que voce ouve). Para descobrir o device correto, rode `pactl list short sources`

### 3. Puxar transcricao

Use a tool `get_transcription` passando o `sessionId`. Os segmentos vem com texto, timestamps, confianca e indicacao de speaker.

### 4. Parar

Use `stop_transcription` para encerrar. A sessao e persistida em `./sessions/{sessionId}.json`.

## Rodar como servidor HTTP (sem Claude Code)

```bash
DEEPGRAM_API_KEY=sua-key .build/debug/App
```

Sobe na porta 8080 com:
- `POST /mcp` — endpoint JSON-RPC para as tools
- `WS /audio/:sessionId` — WebSocket para audio

## Estrutura

```
Sources/App/
  entrypoint.swift              # DI e selecao de modo (stdio vs HTTP)
  Transport/
    StdioTransport.swift        # JSON-RPC via stdin/stdout
    HTTPTransport.swift         # Vapor HTTP + WebSocket
  MCP/
    MCPServer.swift             # Router JSON-RPC
    Tools/                      # Implementacao das 6 tools
  Application/
    TranscriptionService.swift  # Orquestrador (actor)
    SessionService.swift        # Queries de sessao
  Domain/
    Session.swift               # Modelo de sessao
    Segment.swift               # Segmento transcrito
  Infrastructure/
    Providers/
      DeepgramProvider.swift    # WebSocket com Deepgram
    Audio/
      AudioWebSocketHandler.swift  # Recebe audio via WS
    Repositories/
      JSONFileSessionRepository.swift  # Persistencia em JSON
```

## Limitacoes conhecidas

- Suporta apenas **1 sessao ativa por vez** (DeepgramProvider e instancia unica)
- Build debug gera binario de ~40MB. Use `swift build -c release` para producao
