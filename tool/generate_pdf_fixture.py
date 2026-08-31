from pathlib import Path

from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "test" / "fixtures" / "alignment_rotations.pdf"
PAGE_WIDTH = 400
PAGE_HEIGHT = 600


def draw_marker_page(pdf: canvas.Canvas, rotation: int) -> None:
    pdf.setPageSize((PAGE_WIDTH, PAGE_HEIGHT))

    pdf.setStrokeColorRGB(0.08, 0.10, 0.12)
    pdf.setLineWidth(4)
    pdf.rect(12, 12, PAGE_WIDTH - 24, PAGE_HEIGHT - 24)

    corners = (
        (20, 20, (0.85, 0.15, 0.10), "BL"),
        (PAGE_WIDTH - 60, 20, (0.10, 0.55, 0.25), "BR"),
        (20, PAGE_HEIGHT - 60, (0.10, 0.30, 0.85), "TL"),
        (PAGE_WIDTH - 60, PAGE_HEIGHT - 60, (0.85, 0.65, 0.05), "TR"),
    )
    for x, y, color, label in corners:
        pdf.setFillColorRGB(*color)
        pdf.rect(x, y, 40, 40, fill=1, stroke=0)
        pdf.setFillColorRGB(1, 1, 1)
        pdf.setFont("Helvetica-Bold", 10)
        pdf.drawCentredString(x + 20, y + 15, label)

    marker_x = 100
    marker_y = 150
    pdf.setStrokeColorRGB(0.75, 0.05, 0.55)
    pdf.setLineWidth(3)
    pdf.line(marker_x - 18, marker_y, marker_x + 18, marker_y)
    pdf.line(marker_x, marker_y - 18, marker_x, marker_y + 18)
    pdf.circle(marker_x, marker_y, 10, fill=0, stroke=1)

    pdf.setFillColorRGB(0.08, 0.10, 0.12)
    pdf.setFont("Helvetica-Bold", 24)
    pdf.drawString(90, 420, f"PDF /Rotate {rotation}")
    pdf.setFont("Helvetica", 12)
    pdf.drawString(90, 395, "Marker logical point: (100, 150)")
    pdf.showPage()


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    source = OUTPUT.with_suffix(".source.pdf")
    pdf = canvas.Canvas(str(source), pagesize=(PAGE_WIDTH, PAGE_HEIGHT), pageCompression=0)
    pdf.setTitle("OrbitRelay PDF overlay alignment rotations")
    for rotation in (0, 90, 180, 270):
        draw_marker_page(pdf, rotation)
    pdf.save()

    reader = PdfReader(source)
    writer = PdfWriter()
    for page, rotation in zip(reader.pages, (0, 90, 180, 270), strict=True):
        if rotation:
            page.rotate(rotation)
        writer.add_page(page)
    with OUTPUT.open("wb") as stream:
        writer.write(stream)
    source.unlink()
    print(OUTPUT)


if __name__ == "__main__":
    main()
