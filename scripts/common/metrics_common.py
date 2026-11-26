#!/usr/bin/env python3
"""
Módulo común para métricas de operaciones del stack.

Equivalente Python de Metrics-Common.ps1 para uso en scripts Python y crons.
Los datos se guardan en .local/metrics/ como archivos JSONL (append-only).

Uso:
    from metrics_common import start_operation, complete_operation
    
    metric = start_operation("aks", "kubectl_apply", metadata={"namespace": "tools"})
    try:
        # ... operación ...
        complete_operation(metric, "success")
    except Exception as e:
        complete_operation(metric, "failure", error_category="unknown", error_message=str(e))
        raise
"""

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Dict, Any, Literal

# Dominios válidos del stack
VALID_DOMAINS = [
    "azure",
    "aks", 
    "azure-devops-pipelines",
    "azure-devops-permissions",
    "cloudflare",
    "n8n",
    "schema-sync",
    "linux-servers",
    "windows-servers",
    "mcp-health",  # Para el cron de health
    "teams-ops",   # Para el cron de alertas
    "daily-review" # Para el propio Daily Ops Review
]

# Categorías de error
ERROR_CATEGORIES = [
    "validation",
    "network", 
    "auth",
    "timeout",
    "permission",
    "resource_not_found",
    "unknown"
]

# Rutas
REPO_ROOT = os.environ.get("REPO_ROOT", "/home/cursor/stack-cursor")
METRICS_DIR = Path(REPO_ROOT) / ".local" / "metrics"


def start_operation(
    domain: str,
    operation: str,
    session_id: str = "",
    metadata: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """
    Inicia el tracking de una operación.
    
    Args:
        domain: Dominio del stack (azure, aks, azure-devops-pipelines, etc.)
        operation: Nombre de la operación (apply_classic_plan, kubectl_apply, etc.)
        session_id: ID de sesión opcional para correlacionar
        metadata: Datos adicionales sobre la operación
        
    Returns:
        Dict con datos de la métrica iniciada
    """
    if domain not in VALID_DOMAINS:
        raise ValueError(f"Dominio inválido: {domain}. Válidos: {VALID_DOMAINS}")
    
    return {
        "domain": domain,
        "operation": operation,
        "session_id": session_id,
        "started": datetime.now(timezone.utc).isoformat(),
        "metadata": metadata or {}
    }


def complete_operation(
    metric: Dict[str, Any],
    status: Literal["success", "failure", "partial", "skipped"],
    error_category: str = "",
    error_message: str = ""
) -> Dict[str, Any]:
    """
    Completa y guarda una métrica de operación.
    
    Args:
        metric: Objeto retornado por start_operation
        status: Estado final (success, failure, partial, skipped)
        error_category: Categoría del error si status=failure
        error_message: Mensaje de error opcional (truncado a 500 chars)
        
    Returns:
        Dict con el registro completo guardado
    """
    end_time = datetime.now(timezone.utc)
    start_time = datetime.fromisoformat(metric["started"].replace("Z", "+00:00"))
    duration_ms = int((end_time - start_time).total_seconds() * 1000)
    
    record = {
        "domain": metric["domain"],
        "operation": metric["operation"],
        "status": status,
        "duration_ms": duration_ms,
        "timestamp": end_time.isoformat(),
        "session_id": metric.get("session_id", "")
    }
    
    if error_category:
        if error_category not in ERROR_CATEGORIES:
            error_category = "unknown"
        record["error_category"] = error_category
        
    if error_message:
        record["error_message"] = error_message[:500]
        
    if metric.get("metadata"):
        record["metadata"] = metric["metadata"]
    
    # Guardar en archivo JSONL mensual
    _save_record(record)
    
    return record


def _save_record(record: Dict[str, Any]) -> None:
    """Guarda un registro en el archivo JSONL mensual."""
    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    file_path = METRICS_DIR / f"operations-{month}.jsonl"
    
    with open(file_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


def get_error_category(error: Exception) -> str:
    """
    Clasifica un error en una categoría conocida.
    
    Args:
        error: Excepción a clasificar
        
    Returns:
        Categoría del error
    """
    msg = str(error).lower()
    
    if any(x in msg for x in ["timeout", "timed out"]):
        return "timeout"
    if any(x in msg for x in ["401", "403", "unauthorized", "forbidden", "authentication", "login"]):
        return "auth"
    if any(x in msg for x in ["404", "not found", "does not exist"]):
        return "resource_not_found"
    if any(x in msg for x in ["network", "connection", "socket", "dns"]):
        return "network"
    if any(x in msg for x in ["permission", "access denied"]):
        return "permission"
    if any(x in msg for x in ["validation", "invalid", "schema"]):
        return "validation"
    
    return "unknown"


def get_today_failures(domain: Optional[str] = None) -> list:
    """
    Obtiene los fallos de hoy.
    
    Args:
        domain: Filtrar por dominio (opcional)
        
    Returns:
        Lista de registros de fallo
    """
    today = datetime.now(timezone.utc).date()
    month = today.strftime("%Y-%m")
    file_path = METRICS_DIR / f"operations-{month}.jsonl"
    
    if not file_path.exists():
        return []
    
    failures = []
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                record = json.loads(line.strip())
                ts = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                if ts.date() == today and record["status"] == "failure":
                    if domain is None or record["domain"] == domain:
                        failures.append(record)
            except (json.JSONDecodeError, KeyError):
                continue
    
    return failures


def get_today_summary() -> Dict[str, Any]:
    """
    Genera un resumen de las operaciones de hoy.
    
    Returns:
        Dict con resumen por dominio
    """
    today = datetime.now(timezone.utc).date()
    month = today.strftime("%Y-%m")
    file_path = METRICS_DIR / f"operations-{month}.jsonl"
    
    summary = {
        "date": today.isoformat(),
        "total": 0,
        "success": 0,
        "failure": 0,
        "by_domain": {}
    }
    
    if not file_path.exists():
        return summary
    
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                record = json.loads(line.strip())
                ts = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                if ts.date() != today:
                    continue
                    
                summary["total"] += 1
                if record["status"] == "success":
                    summary["success"] += 1
                elif record["status"] == "failure":
                    summary["failure"] += 1
                
                domain = record["domain"]
                if domain not in summary["by_domain"]:
                    summary["by_domain"][domain] = {"total": 0, "success": 0, "failure": 0}
                summary["by_domain"][domain]["total"] += 1
                summary["by_domain"][domain][record["status"]] = summary["by_domain"][domain].get(record["status"], 0) + 1
                
            except (json.JSONDecodeError, KeyError):
                continue
    
    return summary


if __name__ == "__main__":
    # Test básico
    metric = start_operation("linux-servers", "test_operation", metadata={"test": True})
    import time
    time.sleep(0.1)
    result = complete_operation(metric, "success")
    print(f"Métrica guardada: {json.dumps(result, indent=2)}")
    
    print(f"\nResumen de hoy: {json.dumps(get_today_summary(), indent=2)}")
