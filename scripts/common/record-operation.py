#!/usr/bin/env python3
"""
Script CLI para registrar operaciones desde bash.

Uso:
    # Registrar éxito
    python3 scripts/common/record-operation.py success aks kubectl_apply \
        --metadata '{"namespace": "tools", "resource": "deployment/myapp"}'
    
    # Registrar fallo
    python3 scripts/common/record-operation.py failure schema-sync extract \
        --error-category timeout \
        --error-message "Timeout after 40 minutes" \
        --metadata '{"database": "stg_hana"}'

Dominios válidos:
    azure, aks, azure-devops-pipelines, azure-devops-permissions,
    cloudflare, n8n, schema-sync, linux-servers, windows-servers,
    mcp-health, teams-ops, daily-review
"""

import argparse
import json
import sys
from pathlib import Path

# Agregar el directorio common al path
sys.path.insert(0, str(Path(__file__).parent))
from metrics_common import start_operation, complete_operation, VALID_DOMAINS, ERROR_CATEGORIES


def main():
    parser = argparse.ArgumentParser(
        description="Registra una operación en las métricas del stack",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        "status",
        choices=["success", "failure", "partial", "skipped"],
        help="Estado de la operación"
    )
    
    parser.add_argument(
        "domain",
        choices=VALID_DOMAINS,
        help="Dominio del stack"
    )
    
    parser.add_argument(
        "operation",
        help="Nombre de la operación (ej: kubectl_apply, extract, apply_classic_plan)"
    )
    
    parser.add_argument(
        "--error-category",
        choices=ERROR_CATEGORIES,
        default="",
        help="Categoría del error (solo si status=failure)"
    )
    
    parser.add_argument(
        "--error-message",
        default="",
        help="Mensaje de error (truncado a 500 chars)"
    )
    
    parser.add_argument(
        "--metadata",
        default="{}",
        help="JSON con metadata adicional"
    )
    
    parser.add_argument(
        "--duration-ms",
        type=int,
        default=0,
        help="Duración en milisegundos (si se conoce)"
    )
    
    args = parser.parse_args()
    
    # Parsear metadata
    try:
        metadata = json.loads(args.metadata)
    except json.JSONDecodeError:
        print(f"Error: --metadata debe ser JSON válido", file=sys.stderr)
        sys.exit(1)
    
    # Crear métrica
    metric = start_operation(
        domain=args.domain,
        operation=args.operation,
        metadata=metadata
    )
    
    # Si se especificó duración, ajustar el timestamp de inicio
    if args.duration_ms > 0:
        from datetime import datetime, timezone, timedelta
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(milliseconds=args.duration_ms)
        metric["started"] = start_time.isoformat()
    
    # Completar y guardar
    result = complete_operation(
        metric=metric,
        status=args.status,
        error_category=args.error_category,
        error_message=args.error_message
    )
    
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
