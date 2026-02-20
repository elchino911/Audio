#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from statistics import mean

SENDER_RE = re.compile(
    r"stats frame=(?P<frame_ms>\d+)ms tx=(?P<tx_pps>\d+)pps (?P<kbps>[\d.]+)kbps "
    r"cap=(?P<cap_chunks>\d+)chunks/s (?P<cap_samples>\d+)samples/s "
    r"drop=(?P<drop>\d+) q=(?P<queue>\d+)"
    r"(?: avgAbs=(?P<avg_abs>[\d.]+) active=(?P<active_pct>[\d.]+)%)?"
    r"(?: perf capQ=(?P<capq_ms>[\d.]+)ms capSend=(?P<capsend_ms>[\d.]+)ms pkt=(?P<pkt_ms>[\d.]+)ms sock=(?P<sock_ms>[\d.]+)ms)?"
)

RECEIVER_RE = re.compile(
    r"stats\s+rx=(?P<rx_pps>\d+)\s+pps\s+(?P<kbps>[\d.]+)\s+kbps\s+"
    r"delay=(?P<delay>[\d.]+|n/a)\s+ms\s+buffer=(?P<buffer_ms>\d+)\s+ms\s+"
    r"loss=(?P<loss>\d+)\s+late=(?P<late>\d+)\s+over=(?P<over>\d+)\s+"
    r"underrun=(?P<underrun>\d+)\s+parseErr=(?P<parse_err>\d+)\s+payloadErr=(?P<payload_err>\d+)"
)

RECEIVER_PERF_RE = re.compile(
    r"perf\s+netAge=(?P<net_age_ms>[\d.]+|n/a)ms\s+netPath=(?P<net_path_ms>[\d.]+|n/a)ms\s+"
    r"netJit=(?P<net_jit_ms>[\d.]+|n/a)ms\s+decode=(?P<decode_ms>[\d.]+|n/a)ms\s+"
    r"playout=(?P<playout_ms>[\d.]+|n/a)ms\s+e2e=(?P<e2e_ms>[\d.]+|n/a)ms"
)

INIT_RE = re.compile(r"frameMs=(?P<frame_ms>\d+)\s+targetFrames=(?P<target_frames>\d+)")


def safe_mean(values):
    return mean(values) if values else 0.0


def safe_mean_or_none(values):
    vals = [v for v in values if v is not None]
    return mean(vals) if vals else None


def parse_ms(value):
    if value is None or value == "n/a":
        return None
    return float(value)


def fmt(value, digits=1):
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def read_lines_auto(path: Path):
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-16", "utf-16-le", "cp1252", "latin-1"):
        try:
            text = raw.decode(enc)
        except UnicodeDecodeError:
            continue
        # If decode produced mostly NUL chars, it's likely the wrong encoding.
        if text and (text.count("\x00") / len(text)) > 0.1:
            continue
        return text.splitlines()
    return raw.decode("utf-8", errors="ignore").splitlines()


def parse_sender(path: Path):
    rows = []
    for line in read_lines_auto(path):
        m = SENDER_RE.search(line)
        if not m:
            continue
        rows.append(
            {
                "frame_ms": int(m.group("frame_ms")),
                "tx_pps": int(m.group("tx_pps")),
                "kbps": float(m.group("kbps")),
                "cap_chunks": int(m.group("cap_chunks")),
                "cap_samples": int(m.group("cap_samples")),
                "drop": int(m.group("drop")),
                "queue": int(m.group("queue")),
                "avg_abs": float(m.group("avg_abs")) if m.group("avg_abs") is not None else None,
                "active_pct": float(m.group("active_pct")) if m.group("active_pct") is not None else None,
                "capq_ms": float(m.group("capq_ms")) if m.group("capq_ms") is not None else None,
                "capsend_ms": float(m.group("capsend_ms")) if m.group("capsend_ms") is not None else None,
                "pkt_ms": float(m.group("pkt_ms")) if m.group("pkt_ms") is not None else None,
                "sock_ms": float(m.group("sock_ms")) if m.group("sock_ms") is not None else None,
            }
        )
    return rows


def parse_receiver(path: Path):
    rows = []
    perf_rows = []
    init = {"frame_ms": None, "target_frames": None}
    text = "\n".join(read_lines_auto(path))

    im = INIT_RE.search(text)
    if im:
        init["frame_ms"] = int(im.group("frame_ms"))
        init["target_frames"] = int(im.group("target_frames"))

    for m in RECEIVER_RE.finditer(text):
        delay_raw = m.group("delay")
        delay_ms = None if delay_raw == "n/a" else float(delay_raw)
        rows.append(
            {
                "rx_pps": int(m.group("rx_pps")),
                "kbps": float(m.group("kbps")),
                "delay_ms": delay_ms,
                "buffer_ms": int(m.group("buffer_ms")),
                "loss": int(m.group("loss")),
                "late": int(m.group("late")),
                "over": int(m.group("over")),
                "underrun": int(m.group("underrun")),
                "parse_err": int(m.group("parse_err")),
                "payload_err": int(m.group("payload_err")),
            }
        )
    for m in RECEIVER_PERF_RE.finditer(text):
        perf_rows.append(
            {
                "net_age_ms": parse_ms(m.group("net_age_ms")),
                "net_path_ms": parse_ms(m.group("net_path_ms")),
                "net_jit_ms": parse_ms(m.group("net_jit_ms")),
                "decode_ms": parse_ms(m.group("decode_ms")),
                "playout_ms": parse_ms(m.group("playout_ms")),
                "e2e_ms": parse_ms(m.group("e2e_ms")),
            }
        )
    return rows, init, perf_rows


def latency_estimate_ms(summary):
    avg = summary["receiver"]["avg"]
    if avg.get("e2e_ms") is not None:
        return avg["e2e_ms"]
    delay_ms = avg.get("delay_ms") or 0.0
    buffer_ms = avg.get("buffer_ms") or 0.0
    return delay_ms + buffer_ms if delay_ms > 0 else buffer_ms


def score_run(summary):
    # Score 0..100, higher is better.
    s = 100.0
    recv_ps = summary["receiver"]["per_sec"]
    sender_ps = summary["sender"]["per_sec"]

    s -= recv_ps["underrun"] * 25.0
    s -= recv_ps["loss"] * 18.0
    s -= recv_ps["parse_err"] * 50.0
    s -= recv_ps["payload_err"] * 40.0
    s -= recv_ps["over"] * 2.0
    s -= sender_ps["drop"] * 30.0

    # Latency penalty for "sweet spot" search.
    # Prefer low end-to-end latency, but avoid instability.
    latency_ms = latency_estimate_ms(summary)
    if latency_ms > 20:
        s -= (latency_ms - 20) * 0.60
    if latency_ms > 35:
        s -= (latency_ms - 35) * 0.90
    if latency_ms > 60:
        s -= (latency_ms - 60) * 1.30

    net_jit = summary["receiver"]["avg"].get("net_jit_ms")
    if net_jit is not None and net_jit > 5:
        s -= (net_jit - 5) * 0.80

    tx_pps = summary["sender"]["avg"]["tx_pps"]
    rx_pps = summary["receiver"]["avg"]["rx_pps"]
    pps_gap = abs(tx_pps - rx_pps)
    s -= pps_gap * 0.25

    return max(0.0, min(100.0, s))


def summarize_run(label: str, sender_path: Path, receiver_path: Path):
    sender_rows = parse_sender(sender_path)
    receiver_rows, init, receiver_perf_rows = parse_receiver(receiver_path)

    if not sender_rows:
        raise ValueError(f"{label}: sender log has no parsable stats lines")
    if not receiver_rows:
        raise ValueError(f"{label}: receiver log has no parsable stats lines")

    # Ignore warm-up rows where no audio is actually flowing yet.
    sender_rows = [r for r in sender_rows if r["tx_pps"] > 0]
    receiver_rows = [r for r in receiver_rows if r["rx_pps"] > 0]
    if not sender_rows:
        raise ValueError(f"{label}: sender log only contains warm-up rows")
    if not receiver_rows:
        raise ValueError(f"{label}: receiver log only contains warm-up rows")

    # Skip startup transients where buffers are still stabilizing.
    if len(sender_rows) > 8:
        sender_rows = sender_rows[2:]
    if len(receiver_rows) > 8:
        receiver_rows = receiver_rows[2:]

    sender_summary = {
        "samples": len(sender_rows),
        "avg": {
            "tx_pps": safe_mean([r["tx_pps"] for r in sender_rows]),
            "kbps": safe_mean([r["kbps"] for r in sender_rows]),
            "queue": safe_mean([r["queue"] for r in sender_rows]),
            "cap_chunks": safe_mean([r["cap_chunks"] for r in sender_rows]),
            "cap_samples": safe_mean([r["cap_samples"] for r in sender_rows]),
            "avg_abs": safe_mean_or_none([r["avg_abs"] for r in sender_rows]),
            "active_pct": safe_mean_or_none([r["active_pct"] for r in sender_rows]),
            "capq_ms": safe_mean_or_none([r["capq_ms"] for r in sender_rows]),
            "capsend_ms": safe_mean_or_none([r["capsend_ms"] for r in sender_rows]),
            "pkt_ms": safe_mean_or_none([r["pkt_ms"] for r in sender_rows]),
            "sock_ms": safe_mean_or_none([r["sock_ms"] for r in sender_rows]),
        },
        "totals": {
            "drop": sum(r["drop"] for r in sender_rows),
        },
        "per_sec": {
            "drop": sum(r["drop"] for r in sender_rows) / max(1, len(sender_rows)),
        },
        "frame_ms": sender_rows[0]["frame_ms"],
    }

    delays = [r["delay_ms"] for r in receiver_rows if r["delay_ms"] is not None]
    receiver_summary = {
        "samples": len(receiver_rows),
        "avg": {
            "rx_pps": safe_mean([r["rx_pps"] for r in receiver_rows]),
            "kbps": safe_mean([r["kbps"] for r in receiver_rows]),
            "delay_ms": safe_mean_or_none(delays),
            "buffer_ms": safe_mean([r["buffer_ms"] for r in receiver_rows]),
            "net_age_ms": safe_mean_or_none([r["net_age_ms"] for r in receiver_perf_rows]),
            "net_path_ms": safe_mean_or_none([r["net_path_ms"] for r in receiver_perf_rows]),
            "net_jit_ms": safe_mean_or_none([r["net_jit_ms"] for r in receiver_perf_rows]),
            "decode_ms": safe_mean_or_none([r["decode_ms"] for r in receiver_perf_rows]),
            "playout_ms": safe_mean_or_none([r["playout_ms"] for r in receiver_perf_rows]),
            "e2e_ms": safe_mean_or_none([r["e2e_ms"] for r in receiver_perf_rows]),
        },
        "totals": {
            "loss": sum(r["loss"] for r in receiver_rows),
            "late": sum(r["late"] for r in receiver_rows),
            "over": sum(r["over"] for r in receiver_rows),
            "underrun": sum(r["underrun"] for r in receiver_rows),
            "parse_err": sum(r["parse_err"] for r in receiver_rows),
            "payload_err": sum(r["payload_err"] for r in receiver_rows),
        },
        "per_sec": {
            "loss": sum(r["loss"] for r in receiver_rows) / max(1, len(receiver_rows)),
            "late": sum(r["late"] for r in receiver_rows) / max(1, len(receiver_rows)),
            "over": sum(r["over"] for r in receiver_rows) / max(1, len(receiver_rows)),
            "underrun": sum(r["underrun"] for r in receiver_rows) / max(1, len(receiver_rows)),
            "parse_err": sum(r["parse_err"] for r in receiver_rows) / max(1, len(receiver_rows)),
            "payload_err": sum(r["payload_err"] for r in receiver_rows) / max(1, len(receiver_rows)),
        },
        "init": init,
        "perf_samples": len(receiver_perf_rows),
    }

    summary = {
        "label": label,
        "sender_log": str(sender_path),
        "receiver_log": str(receiver_path),
        "sender": sender_summary,
        "receiver": receiver_summary,
    }
    summary["latency_est_ms"] = latency_estimate_ms(summary)
    summary["sweet_score"] = score_run(summary)
    return summary


def find_runs(logs_dir: Path):
    sender = {}
    receiver = {}

    for p in logs_dir.glob("sender_*.log"):
        label = p.stem[len("sender_") :]
        if label.endswith(".err"):
            continue
        sender[label] = p
    for p in logs_dir.glob("receiver_*.log"):
        label = p.stem[len("receiver_") :]
        if label.endswith(".err"):
            continue
        receiver[label] = p

    labels = sorted(set(sender.keys()) & set(receiver.keys()))
    return [(label, sender[label], receiver[label]) for label in labels]


def render_markdown(report):
    lines = []
    lines.append("# Audio Report")
    lines.append("")
    lines.append(f"Runs analizadas: **{len(report['runs'])}**")
    lines.append("")
    best = report.get("best_run")
    if best:
        lines.append(
            f"Punto dulce sugerido: **{best['label']}** (score {best['sweet_score']:.1f}/100)"
        )
        lines.append("")

    lines.append("## Ranking")
    lines.append("")
    lines.append("| Label | Score | Lat est ms | Avg Buffer ms | Underrun | Loss | ParseErr | PayloadErr |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for run in report["runs"]:
        lines.append(
            "| {label} | {score:.1f} | {lat:.1f} | {buffer:.1f} | {underrun} | {loss} | {parse} | {payload} |".format(
                label=run["label"],
                score=run["sweet_score"],
                lat=run["latency_est_ms"],
                buffer=run["receiver"]["avg"]["buffer_ms"],
                underrun=run["receiver"]["totals"]["underrun"],
                loss=run["receiver"]["totals"]["loss"],
                parse=run["receiver"]["totals"]["parse_err"],
                payload=run["receiver"]["totals"]["payload_err"],
            )
        )
    lines.append("")
    lines.append("## Detalle por run")
    lines.append("")
    for run in report["runs"]:
        lines.append(f"### {run['label']}")
        lines.append("")
        lines.append(f"- Score: {run['sweet_score']:.1f}")
        lines.append(
            f"- Sender: tx_pps={run['sender']['avg']['tx_pps']:.1f}, kbps={run['sender']['avg']['kbps']:.1f}, drop_total={run['sender']['totals']['drop']}"
        )
        lines.append(
            f"- Latencia estimada (score): {run['latency_est_ms']:.1f} ms"
        )
        lines.append(
            f"- Receiver: rx_pps={run['receiver']['avg']['rx_pps']:.1f}, kbps={run['receiver']['avg']['kbps']:.1f}, delay_ms={fmt(run['receiver']['avg']['delay_ms'])}, buffer_ms={run['receiver']['avg']['buffer_ms']:.1f}"
        )
        lines.append(
            f"- Perf receiver: netAge={fmt(run['receiver']['avg']['net_age_ms'])} ms, netPath={fmt(run['receiver']['avg']['net_path_ms'])} ms, netJit={fmt(run['receiver']['avg']['net_jit_ms'])} ms, decode={fmt(run['receiver']['avg']['decode_ms'], 3)} ms, playout={fmt(run['receiver']['avg']['playout_ms'])} ms, e2e={fmt(run['receiver']['avg']['e2e_ms'])} ms"
        )
        lines.append(
            f"- Perf sender: capQ={fmt(run['sender']['avg']['capq_ms'], 3)} ms, capSend={fmt(run['sender']['avg']['capsend_ms'], 3)} ms, pkt={fmt(run['sender']['avg']['pkt_ms'], 3)} ms, sock={fmt(run['sender']['avg']['sock_ms'], 3)} ms"
        )
        lines.append(
            f"- Receiver totals: underrun={run['receiver']['totals']['underrun']}, loss={run['receiver']['totals']['loss']}, late={run['receiver']['totals']['late']}, over={run['receiver']['totals']['over']}, parseErr={run['receiver']['totals']['parse_err']}, payloadErr={run['receiver']['totals']['payload_err']}"
        )
        lines.append(
            f"- Receiver por segundo: underrun={run['receiver']['per_sec']['underrun']:.2f}, loss={run['receiver']['per_sec']['loss']:.2f}, over={run['receiver']['per_sec']['over']:.2f}"
        )
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Analiza logs sender/receiver y sugiere el punto dulce de audio."
    )
    parser.add_argument(
        "--logs-dir",
        required=True,
        type=Path,
        help="Directorio con archivos sender_<label>.log y receiver_<label>.log",
    )
    parser.add_argument(
        "--out-json",
        type=Path,
        default=Path("audio_report.json"),
        help="Ruta de salida JSON",
    )
    parser.add_argument(
        "--out-md",
        type=Path,
        default=Path("audio_report.md"),
        help="Ruta de salida Markdown",
    )
    args = parser.parse_args()

    runs = find_runs(args.logs_dir)
    if not runs:
        raise SystemExit(
            "No se encontraron pares de logs. Esperado: sender_<label>.log y receiver_<label>.log"
        )

    summaries = []
    errors = []
    for label, sender_path, receiver_path in runs:
        try:
            summaries.append(summarize_run(label, sender_path, receiver_path))
        except Exception as exc:
            errors.append({"label": label, "error": str(exc)})

    summaries.sort(
        key=lambda r: (
            -r["sweet_score"],
            r["latency_est_ms"],
            r["receiver"]["totals"]["underrun"],
            r["receiver"]["totals"]["loss"],
        )
    )

    report = {
        "runs": summaries,
        "errors": errors,
        "best_run": summaries[0] if summaries else None,
    }

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_md.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    args.out_md.write_text(render_markdown(report), encoding="utf-8")

    print(f"Analisis completado. JSON: {args.out_json}")
    print(f"Analisis completado. MD:   {args.out_md}")
    if report["best_run"]:
        best = report["best_run"]
        print(f"Mejor run: {best['label']} (score={best['sweet_score']:.1f})")
    if errors:
        print("Advertencias:")
        for e in errors:
            print(f"- {e['label']}: {e['error']}")


if __name__ == "__main__":
    main()
