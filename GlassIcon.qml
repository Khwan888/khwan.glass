import QtQuick
import Quickshell

// Frosted-square glyph for the Glass bar icon. Canvas-drawn so it themes
// with the bar foreground and reflects live state: fill density follows
// frost, the diagonal sheen only renders when blur is on.
Canvas {
  id: root

  property real size: 16
  property color color: "#cdd6f4"
  property bool frosted: true
  property bool blurOn: true

  width: size
  height: size
  onColorChanged: requestPaint()
  onFrostedChanged: requestPaint()
  onBlurOnChanged: requestPaint()
  onSizeChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)
    var s = width
    var r = s * 0.18

    // frosted fill — alpha tracks the frost strength
    ctx.globalAlpha = frosted ? 0.75 : 0.25
    ctx.fillStyle = color
    roundedRect(ctx, 1, 1, s - 2, s - 2, r)
    ctx.fill()

    // outline
    ctx.globalAlpha = 1
    ctx.strokeStyle = color
    ctx.lineWidth = Math.max(1.2, s * 0.09)
    roundedRect(ctx, 1, 1, s - 2, s - 2, r)
    ctx.stroke()

    // sheen — only when blur is on
    if (blurOn) {
      ctx.globalAlpha = 0.9
      ctx.strokeStyle = color
      ctx.lineWidth = Math.max(1, s * 0.07)
      ctx.beginPath()
      ctx.moveTo(s * 0.72, s * 0.28)
      ctx.quadraticCurveTo(s * 0.30, s * 0.40, s * 0.28, s * 0.72)
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(s * 0.86, s * 0.45)
      ctx.quadraticCurveTo(s * 0.44, s * 0.57, s * 0.42, s * 0.86)
      ctx.stroke()
    }
    ctx.globalAlpha = 1
  }

  function roundedRect(ctx, x, y, w, h, r) {
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.arcTo(x + w, y, x + w, y + h, r)
    ctx.arcTo(x + w, y + h, x, y + h, r)
    ctx.arcTo(x, y + h, x, y, r)
    ctx.arcTo(x, y, x + w, y, r)
    ctx.closePath()
  }
}
