#pragma once
#include <QImageReader>
#include <QQuickImageProvider>
#include <QUrl>
#include <algorithm>
#include <array>
#include <cmath>

// The secure lock renders with Qt's software backend, where shader effects are
// unavailable. Blur the actual wallpaper on the CPU once, rather than putting
// an ordinary GPU window over the desktop or dropping Cornice's background.
class LockBackground : public QQuickImageProvider {
public:
  QImage image;
  LockBackground() : QQuickImageProvider(QQuickImageProvider::Image) {}
  QImage requestImage(const QString &, QSize *size, const QSize &) override {
    if (size)
      *size = image.size();
    return image;
  }
  void load(const QString &source, double blur) {
    QImageReader reader(QUrl(source).toLocalFile());
    reader.setAutoTransform(true);
    const QSize original = reader.size();
    if (original.width() > 2048 || original.height() > 2048)
      reader.setScaledSize(original.scaled(2048, 2048, Qt::KeepAspectRatio));
    image = reader.read().convertToFormat(QImage::Format_ARGB32_Premultiplied);
    if (image.isNull() || blur <= 0)
      return;
    // Three separable box passes approximate a Gaussian, with sliding sums so
    // cost stays linear in image pixels, independent of the blur radius.
    const int radius =
        std::max(1, int(std::round(std::clamp(blur, 0., 1.) * 16)));
    for (int pass = 0; pass < 3; ++pass) {
      image = box(image, radius, true);
      image = box(image, radius, false);
    }
  }

private:
  static QImage box(const QImage &input, int radius, bool horizontal) {
    QImage output(input.size(), input.format());
    const int length = horizontal ? input.width() : input.height();
    const int lines = horizontal ? input.height() : input.width();
    const int count = radius * 2 + 1;
    for (int line = 0; line < lines; ++line) {
      auto pixel = [&](int pos) {
        pos = std::clamp(pos, 0, length - 1);
        return reinterpret_cast<const QRgb *>(input.constScanLine(
            horizontal ? line : pos))[horizontal ? pos : line];
      };
      std::array<int, 4> sum{};
      auto add = [&](QRgb value, int sign) {
        sum[0] += qRed(value) * sign;
        sum[1] += qGreen(value) * sign;
        sum[2] += qBlue(value) * sign;
        sum[3] += qAlpha(value) * sign;
      };
      for (int pos = -radius; pos <= radius; ++pos)
        add(pixel(pos), 1);
      for (int pos = 0; pos < length; ++pos) {
        reinterpret_cast<QRgb *>(
            output.scanLine(horizontal ? line : pos))[horizontal ? pos : line] =
            qRgba(sum[0] / count, sum[1] / count, sum[2] / count,
                  sum[3] / count);
        add(pixel(pos - radius), -1);
        add(pixel(pos + radius + 1), 1);
      }
    }
    return output;
  }
};
