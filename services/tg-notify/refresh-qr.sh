#!/bin/zsh
set -u

socket_path="$1"
remote_host="$2"
remote_qr_path="${TG_NOTIFY_REMOTE_QR_PATH:-/path/to/tg-notify/data/.qr-url}"

while true; do
  ssh -S "$socket_path" -o ControlMaster=no "$remote_host" \
    "cat '$remote_qr_path'" | swift -e '
      import AppKit
      import CoreImage
      import Foundation

      let input = FileHandle.standardInput.readDataToEndOfFile()
      let filter = CIFilter(name: "CIQRCodeGenerator")!
      filter.setValue(input, forKey: "inputMessage")
      filter.setValue("M", forKey: "inputCorrectionLevel")
      let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 26, y: 26))
      let cgImage = CIContext().createCGImage(image, from: image.extent)!
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
      try! png.write(to: URL(fileURLWithPath: "/tmp/tg-notify-login-live.png"))
    '
  sleep 1
done
