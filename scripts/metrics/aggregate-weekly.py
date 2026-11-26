#!/usr/bin/env python3
"""Agregador semanal de métricas de operaciones.

Lee los archivos JSONL de .local/metrics/ y produce un resumen semanal
en .local/metrics/weekly-summary.json.

Uso:
    python3 aggregate-weekly.py [--weeks N]
    
    --weeks N: Número de semanas hacia atrás a incluir (default: 4)
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path("/home/cursor/stack-cursor")
METRICS_DIR = REPO_ROOT / ".local" / "metrics"


def parse_args():
    weeks = 4
    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--weeks" and i + 2 < len(sys.argv):
            weeks = int(sys.argv[i + 2])
    return weeks


def get_week_key(dt: datetime) -> str:
    """Retorna el identificador de semana ISO: YYYY-Www"""
    return f"{dt.isocalendar().year}-W{dt.isocalendar().week:02d}"


def load_records(start_date: datetime, end_date: datetime) -> list[dict]:
    """Carga todos los registros en el rango de fechas."""
    records = []
    
    # Determinar qué archivos mensuales necesitamos
    months = set()
    current = start_date
    while current <= end_date:
        months.add(current.strftime("%Y-%m"))
        current += timedelta(days=28)
    
    for month in months:
        filepath = METRICS_DIR / f"operations-{month}.jsonl"
        if not filepath.exists():
            continue
        
        with filepath.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                    ts = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                    if start_date <= ts <= end_date:
                        record["_ts"] = ts
                        records.append(record)
                except (json.JSONDecodeError, KeyError, ValueError):
                    continue
    
    return records


def aggregate(records: list[dict]) -> dict:
    """Agrega los registros por semana y dominio."""
    by_week = defaultdict(lambda: {
        "total": 0,
        "success": 0,
        "failure": 0,
        "partial": 0,
        "skipped": 0,
        "by_domain": defaultdict(lambda: {
            "total": 0,
            "success": 0,
            "failure": 0,
            "partial": 0,
            "skipped": 0,
            "durations": [],
        }),
        "errors": defaultdict(int),
    })
    
    for r in records:
        week = get_week_key(r["_ts"])
        status = r.get("status", "unknown")
        domain = r.get("domain", "unknown")
        duration = r.get("duration_ms", 0)
        
        # Totales de la semana
        by_week[week]["total"] += 1
        if status in by_week[week]:
            by_week[week][status] += 1
        
        # Por dominio
        by_week[week]["by_domain"][domain]["total"] += 1
        if status in by_week[week]["by_domain"][domain]:
            by_week[week]["by_domain"][domain][status] += 1
        by_week[week]["by_domain"][domain]["durations"].append(duration)
        
        # Errores
        if status == "failure":
            cat = r.get("error_category", "unknown")
            by_week[week]["errors"][cat] += 1
    
    # Post-procesar: calcular promedios y convertir defaultdicts
    result = {}
    for week, data in sorted(by_week.items()):
        week_data = {
            "total": data["total"],
            "success": data["success"],
            "failure": data["failure"],
            "partial": data["partial"],
            "skipped": data["skipped"],
            "success_rate": round(data["success"] / data["total"] * 100, 1) if data["total"] > 0 else 0,
            "by_domain": {},
            "top_errors": sorted(
                [{"category": k, "count": v} for k, v in data["errors"].items()],
                key=lambda x: -x["count"]
            )[:5],
        }
        
        for domain, ddata in data["by_domain"].items():
            durations = ddata.pop("durations", [])
            avg_duration = int(sum(durations) / len(durations)) if durations else 0
            ddata["avg_duration_ms"] = avg_duration
            ddata["success_rate"] = round(ddata["success"] / ddata["total"] * 100, 1) if ddata["total"] > 0 else 0
            week_data["by_domain"][domain] = dict(ddata)
        
        result[week] = week_data
    
    return result


def main():
    weeks = parse_args()
    
    now = datetime.now(timezone.utc)
    end_date = now
    start_date = now - timedelta(weeks=weeks)
    
    print(f"Agregando métricas de {start_date.date()} a {end_date.date()}...")
    
    records = load_records(start_date, end_date)
    print(f"  Registros cargados: {len(records)}")
    
    if not records:
        print("  No hay datos para agregar.")
        summary = {
            "generated_at": now.isoformat(),
            "period": {
                "start": start_date.isoformat(),
                "end": end_date.isoformat(),
                "weeks": weeks,
            },
            "total_operations": 0,
            "by_week": {},
        }
    else:
        by_week = aggregate(records)
        
        # Calcular totales globales
        total = sum(w["total"] for w in by_week.values())
        success = sum(w["success"] for w in by_week.values())
        
        summary = {
            "generated_at": now.isoformat(),
            "period": {
                "start": start_date.isoformat(),
                "end": end_date.isoformat(),
                "weeks": weeks,
            },
            "total_operations": total,
            "overall_success_rate": round(success / total * 100, 1) if total > 0 else 0,
            "by_week": by_week,
        }
    
    # Guardar
    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    output_path = METRICS_DIR / "weekly-summary.json"
    output_path.write_text(json.dumps(summary, indent=2))
    print(f"  Resumen guardado en: {output_path}")
    
    # Imprimir resumen
    if summary["total_operations"] > 0:
        print(f"\n=== Resumen ===")
        print(f"  Operaciones totales: {summary['total_operations']}")
        print(f"  Tasa de éxito: {summary['overall_success_rate']}%")
        print(f"  Semanas con datos: {len(summary['by_week'])}")


if __name__ == "__main__":
    main()
