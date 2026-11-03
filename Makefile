.PHONY: build app run test smoke live-smoke

build:
	swift build

app:
	bash scripts/build-app.sh

run: app
	open "dist/Word Hunt Solver.app"

test:
	swift test --disable-xctest --enable-swift-testing

smoke:
	swift run WordHuntSolver self-check --output .build/smoke

live-smoke:
	swift run WordHuntSolver practice-check --output .build/system-smoke
