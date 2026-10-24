.PHONY: demo build test app universal run-app release previews e2e l10n icon clean

build:
	swift build

test:
	swift test

app:
	Scripts/build-app.sh

universal:
	ARCHS="arm64 x86_64" Scripts/build-app.sh

run-app: app
	open build/Airbag.app

release:
	Scripts/package.sh

previews: app
	build/Airbag.app/Contents/MacOS/Airbag --render-previews build/previews

# README video (MP4 + GIF) from the app's real screens, and light/dark screenshots (needs Pillow).
demo: app
	rm -rf build/demo build/previews-en
	build/Airbag.app/Contents/MacOS/Airbag --render-demo build/demo/screens -AppleLanguages "(en)"
	python3 Scripts/make-demo-video.py build/demo/screens build/demo
	swiftc -O Scripts/encode-video.swift -o build/demo/encode-video
	build/demo/encode-video build/demo/frames docs/images/airbag-demo.mp4 30
	cp build/demo/demo.gif docs/images/demo.gif
	build/Airbag.app/Contents/MacOS/Airbag --render-previews build/previews-en -AppleLanguages "(en)"
	for f in popover main-timeline main-radar main-guard restore; do cp build/previews-en/$$f-light.png build/previews-en/$$f-dark.png docs/images/; done
	for m in light dark; do cp build/previews-en/welcome-3-$$m.png docs/images/welcome-$$m.png; done

e2e:
	python3 -I Scripts/e2e-hooks.py

l10n:
	python3 -I Scripts/check-l10n.py

icon:
	swift Scripts/make-icon.swift "$(CURDIR)"

clean:
	rm -rf .build build
