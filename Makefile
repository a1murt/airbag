.PHONY: build test app universal run-app cli clean

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

cli:
	swift build -c release --product airbag && cp "$$(swift build -c release --show-bin-path)/airbag" build/airbag

clean:
	rm -rf .build build
