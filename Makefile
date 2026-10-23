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

# README hero animation and screenshots from English light/dark previews (needs Pillow).
demo: app
	rm -rf build/previews-en && build/Airbag.app/Contents/MacOS/Airbag --render-previews build/previews-en -AppleLanguages "(en)"
	python3 Scripts/make-demo-gif.py build/previews-en docs/images/demo.gif
	for f in popover main-timeline main-radar main-guard restore welcome; do cp build/previews-en/$$f-light.png build/previews-en/$$f-dark.png docs/images/; done

e2e:
	python3 -I Scripts/e2e-hooks.py

l10n:
	python3 -I Scripts/check-l10n.py

icon:
	swift Scripts/make-icon.swift "$(CURDIR)"

clean:
	rm -rf .build build
