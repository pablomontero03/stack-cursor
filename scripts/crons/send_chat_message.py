"""teams-ops :: helper de envío de mensajes a chats de Teams via Graph API.

Uso (llamado desde bash por el agente tras aprobación de Pablo):

  python3 send_chat_message.py <chat_id> <msg_id_reply_to> "<texto>"

  - chat_id      : ID del chat (de pending_candidates en chat-state.json)
  - msg_id       : ID del mensaje al que se responde (para contexto; NO es un
                   "reply thread" de Teams — eso requiere otro endpoint). Pasar
                   "" si no se quiere referenciar.
  - texto        : Contenido del mensaje a enviar (texto plano, se envía como
                   content HTML con <p>texto</p> que Teams renderiza limpio).

Autenticación: mismo token MSAL que usa teams_chats.py (cache en
~/.teams-mcp-token-cache.json, client Graph CLI 14d82eec). Se refresca
automáticamente desde el refresh_token.

Escribe el resultado (mensaje_id enviado o error) a stdout para que el agente
lo capture y actualice chat-state.json.
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

TENANT = "33dd4184-3068-47da-891d-a70e02f8c0c9"
CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
TOKEN_CACHE = Path.home() / ".teams-mcp-token-cache.json"
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
SCOPE = "https://graph.microsoft.com/.default"
GRAPH_BASE = "https://graph.microsoft.com/v1.0"


def _http_post_form(url: str, data: dict) -> dict:
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def _http_post_json(url: str, token: str, payload: dict) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def _get_access_token() -> str:
    cache = json.loads(TOKEN_CACHE.read_text())
    rt_entry = next(iter(cache.get("RefreshToken", {}).values()), None)
    if not rt_entry:
        raise RuntimeError("no refresh token in teams-mcp cache")
    refresh_secret = rt_entry["secret"]
    resp = _http_post_form(
        TOKEN_URL,
        {"client_id": CLIENT_ID, "grant_type": "refresh_token",
         "refresh_token": refresh_secret, "scope": SCOPE},
    )
    tok = resp.get("access_token")
    if not tok:
        raise RuntimeError(f"token refresh failed: {resp.get('error_description', resp)}")
    # Actualizar el RT en cache si cambió
    new_rt = resp.get("refresh_token")
    if new_rt and new_rt != refresh_secret:
        for k in list(cache.get("RefreshToken", {})):
            cache["RefreshToken"][k]["secret"] = new_rt
        TOKEN_CACHE.write_text(json.dumps(cache))
    return tok


def send_message(chat_id: str, text: str) -> str:
    """Envía `text` al chat `chat_id`. Devuelve el id del mensaje creado."""
    token = _get_access_token()
    url = f"{GRAPH_BASE}/chats/{chat_id}/messages"
    # Graph API acepta HTML en body.content; <p> renderiza como texto limpio en Teams.
    # Se escapan los caracteres HTML básicos para evitar inyección accidental.
    safe = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    payload = {
        "body": {
            "contentType": "html",
            "content": f"<p>{safe}</p>",
        }
    }
    resp = _http_post_json(url, token, payload)
    msg_id = resp.get("id")
    if not msg_id:
        raise RuntimeError(f"send failed, response: {json.dumps(resp)[:300]}")
    return msg_id


def main() -> None:
    if len(sys.argv) < 3:
        print("uso: python3 send_chat_message.py <chat_id> <texto>", file=sys.stderr)
        sys.exit(1)

    chat_id = sys.argv[1]
    # El texto puede venir como tercer argumento o desde stdin si es muy largo.
    if sys.argv[2] == "-":
        text = sys.stdin.read().strip()
    else:
        text = " ".join(sys.argv[2:])

    if not text:
        print("ERROR: texto vacío", file=sys.stderr)
        sys.exit(1)

    try:
        sent_id = send_message(chat_id, text)
        # Registrar el sent_id en chat-state.json para que el cron no lo reprocese como candidato.
        # También marcar el chat como conversación activa (hay un intercambio en curso).
        STATE_FILE = Path("/home/cursor/stack-cursor/.local/teams-ops/chat-state.json")
        try:
            state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
            sent_ids = state.get("agent_sent_ids", [])
            sent_ids.append(sent_id)
            state["agent_sent_ids"] = sent_ids[-200:]  # mantener últimos 200
            # Registrar conversación activa: {chat_id: sent_id}
            # El agente usa esto para saber que ya hay un intercambio en curso.
            active_convs = state.get("active_conversations", {})
            active_convs[chat_id] = {"last_agent_msg": sent_id, "ts": __import__("datetime").datetime.utcnow().isoformat()}
            # Limpiar conversaciones viejas (> 24h sin actividad)
            import datetime as _dt
            cutoff = (_dt.datetime.utcnow() - _dt.timedelta(hours=24)).isoformat()
            active_convs = {k: v for k, v in active_convs.items() if v.get("ts", "") >= cutoff}
            state["active_conversations"] = active_convs
            STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False))
        except Exception:
            pass  # no bloquear el envío por un error al guardar el estado
        # Salida JSON para que el agente la parsee fácilmente.
        print(json.dumps({"ok": True, "sent_id": sent_id, "chat_id": chat_id}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
