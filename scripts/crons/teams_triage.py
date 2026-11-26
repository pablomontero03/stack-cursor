"""teams-ops :: triage de alertas (cron SCRIPT, sin LLM / sin ACP).

Polla el canal ALERTAS Clusters-Servidores (team Monitoreo) vía Microsoft Graph
Search API usando el token read-only de teams-mcp (MSAL cache). Clasifica cada
card 🔴/🟢, lleva estado por recurso y SOLO despierta al agente cuando una alerta
se CONFIRMA (anti-falso-positivo):

  - flap >= FLAP_THRESHOLD veces (🔴 que recupera y vuelve) sobre el mismo recurso, o
  - 🔴 persistente sin recovery por >= PERSIST_THRESHOLD ciclos.

Una 🔴 que recupera enseguida y no reincide = falso positivo => no despierta.

Diseño: sin LLM (código determinista), sin sesión ACP (evita el bug del lock de
cli.json que mata al cron-agente). El runner síncrono inyecta un ScriptContext `ctx`.
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

from kiro_crew.cron_script import Report, Skip

CR_TZ = timezone(timedelta(hours=-6))  # Costa Rica, UTC-6 (sin DST)


def _cr(iso: str) -> str:
    """Convierte un timestamp ISO (UTC o con offset) a hora local CR legible."""
    if not iso:
        return "?"
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.astimezone(CR_TZ).strftime("%Y-%m-%d %H:%M CR")
    except Exception:
        return iso

# ---- Canales monitoreados (ampliado 2026-11-04) ----
# Canal semilla: ALERTAS Clusters-Servidores (confirmado en vivo 2026-10-13)
# Canal agregado: Sites (certificados TLS/SSL, ampliado por Pablo 2026-11-04)
CHANNEL_IDS = {
    "19:97a29bb31e7c4792be94222009f7be01@thread.tacv2",  # ALERTAS Clusters-Servidores
    "19:592c85e5b598468bb9cec6115543d525@thread.tacv2",  # Sites (certificados SSL)
}
CHANNEL_ID = "19:97a29bb31e7c4792be94222009f7be01@thread.tacv2"  # legado: usado en notify_msg
TENANT = "33dd4184-3068-47da-891d-a70e02f8c0c9"
CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Graph CLI public client
TOKEN_CACHE = Path.home() / ".teams-mcp-token-cache.json"
STATE_FILE = Path(
    "/home/cursor/stack-cursor/.local/teams-ops/alert-state.json"
)

# ---- Umbrales de confirmación (ajustables) ----
FLAP_THRESHOLD = 3        # 🔴→🟢 repetido N veces sobre el mismo recurso = válido
PERSIST_THRESHOLD = 3     # 🔴 sin recovery por N ciclos consecutivos = válido
NOTIFY_COOLDOWN_HOURS = 6  # no re-despertar por el mismo recurso dentro de esta ventana
# Cooldowns específicos por tipo (sobrescriben el default)
NOTIFY_COOLDOWN_BY_TYPE = {
    "certificados": 12,  # certs no cambian en horas; monitor dispara cada 5h
    "pvc/pv disk usage": 12,  # error de sensor crónico, no urgente
    "cpu/memory usage": 24,  # monitor muy ruidoso en prod; una notificación diaria máximo
}
SEARCH_QUERY = "AKS OR ALERTA OR RECOVERY OR CERTIFICADO"

GRAPH_SEARCH_URL = "https://graph.microsoft.com/v1.0/search/query"
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
SCOPE = "https://graph.microsoft.com/.default"

CARD_PREFIX_RE = re.compile(r"^.*?(?=[🔴🟢])", re.S)  # corta todo hasta el 1er emoji de estado


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
    """Refresca el access token con el refresh token del cache MSAL (urllib puro)."""
    cache = json.loads(TOKEN_CACHE.read_text())
    rt_entry = next(iter(cache.get("RefreshToken", {}).values()), None)
    if not rt_entry:
        raise RuntimeError("no refresh token in teams-mcp cache")
    refresh_secret = rt_entry["secret"]
    resp = _http_post_form(
        TOKEN_URL,
        {
            "client_id": CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh_secret,
            "scope": SCOPE,
        },
    )
    tok = resp.get("access_token")
    if not tok:
        raise RuntimeError(f"token refresh failed: {resp.get('error_description', resp)}")
    # Persistir el refresh token rotado (si vino uno nuevo) para no quedar fuera.
    new_rt = resp.get("refresh_token")
    if new_rt and new_rt != refresh_secret:
        rt_entry["secret"] = new_rt
        for k, v in cache["RefreshToken"].items():
            if v is rt_entry:
                cache["RefreshToken"][k] = rt_entry
                break
        TOKEN_CACHE.write_text(json.dumps(cache))
    return tok


def _search_channel(token: str) -> list[dict]:
    """Search API: trae mensajes recientes; filtra a los canales monitoreados.

    Los hits vienen rankeados por relevancia (no por fecha). Se ordenan por
    createdDateTime ASC para que el procesamiento posterior aplique las cards
    en orden cronológico correcto: si llegan una ALERTA y su RECOVERY en el
    mismo intervalo de 5 min, la RECOVERY (más reciente) gana como last_estado.
    Sin este orden la ALERTA puede rankear más alto y dejar el estado "stuck".
    """
    payload = {
        "requests": [
            {
                "entityTypes": ["chatMessage"],
                "query": {"queryString": SEARCH_QUERY},
                "from": 0,
                "size": 50,
            }
        ]
    }
    data = _http_post_json(GRAPH_SEARCH_URL, token, payload)
    hits = []
    for resp in data.get("value", []):
        for container in resp.get("hitsContainers", []):
            for hit in container.get("hits", []):
                res = hit.get("resource", {})
                # channelIdentity.channelId para canales de Teams; chatId como fallback (algunos canales)
                chan = (res.get("channelIdentity") or {}).get("channelId") or res.get("chatId") or hit.get("chatId")
                if chan not in CHANNEL_IDS:
                    continue
                summary = hit.get("summary", "") or ""
                mid = res.get("id") or hit.get("hitId")
                created = res.get("createdDateTime", "")
                hits.append({"id": mid, "summary": summary, "created": created})
    # Ordenar ASC por fecha para procesar en orden cronológico (más antiguo primero).
    # Así la card más reciente del mismo recurso es la que queda como last_estado.
    hits.sort(key=lambda h: h.get("created", ""))
    return hits


def _clean(summary: str) -> str:
    """Deja el texto desde el primer emoji de estado 🔴/🟢 (quita el prefijo 'Card - ...')."""
    m = CARD_PREFIX_RE.match(summary or "")
    if m and m.end() < len(summary or ""):
        return summary[m.end():].strip()
    return (summary or "").strip()


def _classify(text: str) -> dict:
    """Extrae estado y una clave de recurso estable del texto de la card.

    El estado se decide por el EMOJI (🔴/🟢), NO por la palabra 'Recovery': una card
    de ALERTA incluye la línea 'Recovery: <= 90%' (umbral configurado) y eso no la
    convierte en recovery.
    """
    has_red = "🔴" in text
    has_green = "🟢" in text
    if has_green and not has_red:
        estado = "RECOVERY"
    elif has_red and not has_green:
        estado = "ALERTA"
    else:
        up = text[:60].upper()
        estado = "RECOVERY" if "RECOVERY" in up else ("ALERTA" if "ALERT" in up else "FYI")
    # título/monitor: sin emojis/asteriscos, hasta 'Hora'/'Estado'/'|'
    titulo = re.sub(r"[🔴🟢*]+", " ", text)
    titulo = re.split(r"\bHora\b|\bEstado\b|\bUmbral\b|\|", titulo, flags=re.I)[0].strip()[:120] or text[:80]
    # clave de recurso: el monitor sin palabras de estado/ruido, para agrupar flaps del mismo recurso
    key = re.sub(r"\b(ALERTA|RECOVERY|TOTAL|PARCIAL|ALERT|ALERTAS|Monitor|Estado|v\d+)\b", "", titulo, flags=re.I)
    key = re.sub(r"[-–—]+", " ", key)
    key = re.sub(r"\s+", " ", key).strip(" -:·•").lower()[:80] or "generic"
    # ambiente por nombre
    low = text.lower()
    if "prod" in low:
        amb = "produccion"
    elif "uat" in low:
        amb = "uat"
    elif "dev" in low or "desarrollo" in low:
        amb = "dev"
    else:
        amb = "desconocido"
    # dominio del stack
    if "aks" in low or "pvc" in low or " pod" in low:
        dom = "aks"
    elif "certificado" in low or "tls" in low or "ssl" in low or "cert " in low or "vence" in low:
        dom = "cloudflare/sitios"
    elif "disco" in low or "backup" in low or "sql" in low or "indice" in low or "índice" in low or "fragmentac" in low:
        dom = "schema-sync/db"
    elif "nodo" in low or "vm" in low:
        dom = "azure"
    else:
        dom = "por-clasificar"
    return {"estado": estado, "key": key, "titulo": titulo, "ambiente": amb, "dominio": dom}


def _load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"last_run_utc": None, "seen_ids": [], "resources": {}, "awoke_for": [], "last_notified_ts": {}}


def _save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False))


def run(ctx):  # noqa: C901  (el runner síncrono inyecta ctx)
    now = datetime.now(timezone.utc).isoformat()
    state = _load_state()
    seen = set(state.get("seen_ids", []))
    resources: dict = state.get("resources", {})
    awoke_for: set = set(state.get("awoke_for", []))
    last_notified_ts: dict = state.get("last_notified_ts", {})

    try:
        token = _get_access_token()
        hits = _search_channel(token)
    except Exception as e:  # red/token: no romper el cron, reintentar luego
        state["last_run_utc"] = now
        state["last_error"] = str(e)[:300]
        _save_state(state)
        raise Skip(f"teams-ops poll error (reintenta): {e}")

    # Ordenar por id ascendente (los ids de Teams son monotónicos por tiempo)
    hits.sort(key=lambda h: str(h.get("id") or ""))
    new_hits = [h for h in hits if h["id"] not in seen]

    confirmados = []  # recursos que cruzaron el umbral en esta corrida

    for h in new_hits:
        seen.add(h["id"])
        text = _clean(h["summary"])
        info = _classify(text)
        key = info["key"]
        r = resources.setdefault(
            key,
            {"alerts": 0, "recoveries": 0, "flaps": 0, "persist": 0,
             "last_estado": None, "ambiente": info["ambiente"], "dominio": info["dominio"],
             "titulo": info["titulo"]},
        )
        r["ambiente"] = info["ambiente"]
        r["dominio"] = info["dominio"]
        r["titulo"] = info["titulo"]
        r["last_msg_id"] = h["id"]  # para que el agente traiga el cuerpo completo al despertar

        if info["estado"] == "ALERTA":
            r["alerts"] += 1
            r["persist"] += 1  # consecutivas sin recovery
            r["last_estado"] = "ALERTA"
        elif info["estado"] == "RECOVERY":
            r["recoveries"] += 1
            if r["last_estado"] == "ALERTA":
                r["flaps"] += 1  # un ciclo 🔴->🟢 completo
            r["persist"] = 0     # recuperó: corta la racha de persistencia
            r["last_estado"] = "RECOVERY"
            # Solo limpiar el cooldown si es un RECOVERY TOTAL (sin "PARCIAL" en el título)
            # y solo para recursos que no tienen cooldown extendido por tipo.
            # Para monitores muy ruidosos (cpu/memory, certs, pvc), el recovery
            # NO resetea el last_notified_ts — solo limpia awoke_for para que
            # una próxima alerta pase el guard de awoke_for, pero el cooldown por
            # tiempo sigue activo.
            is_total = "parcial" not in info["titulo"].lower()
            if is_total:
                awoke_for.discard(key)
                # Solo borrar last_notified_ts si no tiene cooldown extendido
                has_extended_cd = any(tipo in key.lower() for tipo in NOTIFY_COOLDOWN_BY_TYPE)
                if not has_extended_cd:
                    last_notified_ts.pop(key, None)

        # ¿cruzó umbral de confirmación?
        valid_flap = r["flaps"] >= FLAP_THRESHOLD
        valid_persist = r["persist"] >= PERSIST_THRESHOLD
        if valid_flap or valid_persist:
            # Cooldown por tipo: no re-despertar antes de que expire la ventana
            cooldown_h = NOTIFY_COOLDOWN_HOURS
            for tipo, horas in NOTIFY_COOLDOWN_BY_TYPE.items():
                if tipo in key.lower():
                    cooldown_h = horas
                    break
            last_ts = last_notified_ts.get(key)
            in_cooldown = False
            if last_ts:
                try:
                    last_dt = datetime.fromisoformat(last_ts)
                    elapsed_h = (datetime.now(timezone.utc) - last_dt).total_seconds() / 3600
                    in_cooldown = elapsed_h < cooldown_h
                except Exception:
                    pass
            # Si el cooldown venció, limpiar awoke_for para permitir re-notificar.
            # awoke_for solo tiene sentido dentro de la ventana de cooldown.
            if not in_cooldown:
                awoke_for.discard(key)
            if not in_cooldown and key not in awoke_for:
                awoke_for.add(key)
                motivo = (
                    f"flap x{r['flaps']}" if valid_flap else f"persistente x{r['persist']} sin recovery"
                )
                confirmados.append({**info, "key": key, "motivo": motivo,
                                    "alerts": r["alerts"], "recoveries": r["recoveries"],
                                    "last_msg_id": r.get("last_msg_id")})

    state["last_run_utc"] = now
    state["seen_ids"] = sorted(seen)[-500:]  # cap para no crecer sin límite
    state["resources"] = resources
    state["awoke_for"] = sorted(awoke_for)
    # Registrar el timestamp de notificación para el cooldown
    for c in confirmados:
        last_notified_ts[c["key"]] = now
    state["last_notified_ts"] = last_notified_ts
    state.pop("last_error", None)
    _save_state(state)

    if not confirmados:
        # corrida silenciosa: nada confirmado -> Skip (NO notifica; queda en historial del cron)
        raise Skip(
            f"teams-ops: {len(new_hits)} msg nuevos, 0 alertas confirmadas (silencioso)."
        )

    # Hay alerta(s) CONFIRMADA(s): despertar al agente para diagnóstico/enrutamiento.
    lineas = []
    for c in confirmados:
        lineas.append(
            f"🔴 CONFIRMADA [{c['motivo']}] — {c['titulo']} | dominio={c['dominio']} | "
            f"alerts={c['alerts']} recoveries={c['recoveries']} | last_msg_id={c.get('last_msg_id','?')}"
        )
    msg = (
        f"teams-ops [FASE AUTÓNOMA dev/uat] ({_cr(now)}): alerta(s) CONFIRMADA(s). "
        "Nota: la 'Hora local' dentro de la card ya viene en CR.\n\n"
        + "\n".join(lineas)
        + "\n\nQUÉ HACER (agente):\n"
        "--- ALERTAS CLUSTERS-SERVIDORES (canal AKS/infra) ---\n"
        "1. Trae el CUERPO COMPLETO de la card AKS (summary truncado): "
        "GET https://graph.microsoft.com/v1.0/teams/d562abdf-c5fc-4f41-b7ab-30bf2e23e298/"
        "channels/19:97a29bb31e7c4792be94222009f7be01@thread.tacv2/messages/<last_msg_id> "
        "→ attachments[0].content (JSON AdaptiveCard con el detalle por alerta).\n"
        "2. Extrae SOLO las ALERTAS reales (ignora las WARNINGS: contexto, no se atienden).\n"
        "3. Clasifica ambiente por cluster/namespace:\n"
        "   - DESARROLLO o UAT → AUTONOMÍA TOTAL, SIN pedir aprobación: diagnostica, corrige en el "
        "pipeline que corresponda (VG/manifiesto/Release del dominio — delega al ado-pipeline-builder "
        "para el PUT seguro; nunca kubectl patch suelto que el pipeline aplane), encola el Release de "
        "dev/uat, verifica en el cluster. Un scale operativo (bajar/subir pod) es kubectl scale directo, "
        "no pipeline.\n"
        "   - PRODUCCIÓN (gmon-prod-* / sqlmi prod / .31 prod) → NO toques nada: diagnostica y PROPÓN "
        "el cambio, espera OK de Pablo.\n"
        "4. Código de app (bug/SQL/lógica) → reporta al dev con evidencia, nunca lo toques.\n\n"
        "--- SITES (canal certificados SSL/sitios web) ---\n"
        "Si la alerta viene del canal Sites (certificados TLS/SSL, accesibilidad de URLs):\n"
        "A. VALIDACIÓN CRUZADA: revisa primero el estado actual del canal ALERTAS Clusters-Servidores "
        "(search_messages canal 19:97a29bb31e7c4792be94222009f7be01@thread.tacv2). Si hay alertas AKS "
        "activas (pods caídos, alta memoria, reinicios) relacionadas con el sitio que falla, el problema "
        "puede ser de infra — diagnostica por el dominio aks. Si no hay correlación AKS, el sitio puede "
        "ser un falso positivo o un problema de cert/DNS/Cloudflare.\n"
        "B. VALIDACIÓN DE SITIO (si no hay causa AKS): para cada URL en alerta, verifica:\n"
        "   1. Conectividad HTTP: curl -sk --max-time 10 -o /dev/null -w '%{http_code}' <URL>\n"
        "   2. Certificado SSL: curl -vvI --max-time 10 <URL> 2>&1 | grep -E 'expire|subject|issuer'\n"
        "   3. DNS: dig +short <host>\n"
        "   4. Si el sitio está detrás de Cloudflare y responde 521/522/523, revisar el ingress/pod en el "
        "cluster que corresponda (dominio cloudflare + aks).\n"
        "C. CLASIFICACIÓN:\n"
        "   - Cert vencido/por vencer → dominio cloudflare (renovar) o azure (si es cert de Azure).\n"
        "   - Sitio inaccessible pero cert OK → probable pod caído o ingress roto → dominio aks.\n"
        "   - Falso positivo (sitio responde 200 y cert válido) → registrar como FP y no actuar.\n"
        "   - PRODUCCIÓN → solo reportar + proponer, no actuar sin OK de Pablo.\n\n"
        "--- CIERRE ---\n"
        "5. REPORTA AL CIERRE con send_message. Formato dev/uat: 'teams-ops [AUTO-FIX dev/uat]: <alerta>' "
        "+ Diagnóstico / Cambio (VG/Release/replica) / Verificación (estado en cluster) / Dominio. "
        "Formato prod: '🔴 PROD — requiere decisión' + cambio propuesto sin ejecutar.\n"
        "6. Enruta siempre al dominio del stack y cítalo (aks/azure-devops-pipelines/azure/cloudflare/...)."
    )
    ctx.notify(msg)
    raise Report(f"teams-ops: {len(confirmados)} alerta(s) confirmada(s) — fase autónoma dev/uat.")
