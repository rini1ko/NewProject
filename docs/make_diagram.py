"""Regenerates docs/architecture-container-ai.png (C4 level 2 with the agenda parser)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

fig, ax = plt.subplots(figsize=(14, 9), dpi=140)
ax.set_xlim(0, 140); ax.set_ylim(0, 90); ax.axis("off")
STYLES = {"blue": ("#e6f0fa", "#1f5fa8", "#0f3d72", "#1f5fa8"),
          "red": ("#f9ebe6", "#a8431f", "#6b2610", "#a8431f"),
          "green": ("#e4f5e8", "#2a8a46", "#14532d", "#2a8a46")}

def zone(x, y, w, h, label):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=4", fc="#f1eee8", ec="#555", lw=1))
    ax.text(x + 3, y + h - 3, label, fontsize=13, va="top", weight="bold")

def box(x, y, w, h, title, sub, kind="blue"):
    fc, ec, tc, sc = STYLES[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=2.5", fc=fc, ec=ec, lw=2.5 if kind == "green" else 1.5))
    ax.text(x + w / 2, y + h * .62, title, ha="center", va="center", fontsize=12.5, weight="bold", color=tc)
    ax.text(x + w / 2, y + h * .28, sub, ha="center", va="center", fontsize=9.5, color=sc)

def arrow(p, q, label="", color="#888", lw=2, at=None, both=False):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="<->" if both else "->", mutation_scale=16, color=color, lw=lw, shrinkA=0, shrinkB=0))
    if label:
        x, y = at or ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)
        ax.text(x, y, label, fontsize=9, ha="center", va="center", color=color if color != "#888" else "#444",
                bbox=dict(fc="white", ec="none", pad=1.2, alpha=.9))

zone(30, 72, 80, 16, "Browser")
box(42, 73, 56, 9, "Frontend", "React + Tailwind (S3 + CloudFront)")
zone(2, 24, 62, 44, "AWS: VPC (no NAT)")
box(7, 44, 52, 12, "Backend API Lambda", "FastAPI: validates, saves, reads")
box(7, 29, 36, 10, "Aurora PostgreSQL", "meetings, meeting_agendas")
zone(72, 38, 66, 30, "AWS: outside the VPC (new)")
box(78, 42, 54, 12, "agenda-parser Lambda", "function URL · Cognito token · limits · validates", "green")
box(78, 6, 54, 12, "Amazon Bedrock", "Claude (IAM role, no API key)", "green")
box(7, 6, 52, 12, "Amazon Cognito", "sign-in, ID tokens (JWKS)", "red")

arrow((48, 73), (35, 56), "save: PUT agenda + ai_suggestion", at=(30, 66))
arrow((90, 73), (102, 54), "parse: text, today, tz", color="#2a8a46", lw=2.6, at=(113, 61))
arrow((25, 44), (25, 39), "SQL", at=(30, 41.5), both=True)
arrow((105, 42), (105, 18), "InvokeModel", color="#2a8a46", lw=2.6, at=(113, 30))
arrow((52, 44), (52, 18), "verify token", at=(46, 22))
arrow((78, 46), (59, 15), "verify token (JWKS)", at=(70, 30))
ax.text(70, 1.5, "The model suggests; the person decides. The parser never writes: Save goes through the API.",
        ha="center", fontsize=10.5, style="italic", color="#333")
plt.savefig("docs/architecture-container-ai.png", bbox_inches="tight", facecolor="white")
