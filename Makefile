.PHONY: build test app universal run-app release previews e2e l10n icon clean

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

e2e:
	python3 -I Scripts/e2e-hooks.py

l10n:
	python3 -I Scripts/check-l10n.py

icon:
	swift Scripts/make-icon.swift "$(CURDIR)"

clean:
	rm -rf .build build
