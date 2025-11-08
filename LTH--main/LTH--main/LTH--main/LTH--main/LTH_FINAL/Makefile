.PHONY: build clean test run gui tui server client help install

# Default target
all: build

# Build the project
build:
	@echo "🔨 Building project..."
	stack build

# Clean build artifacts
clean:
	@echo "🧹 Cleaning..."
	stack clean
	rm -rf .stack-work/
	rm -rf saves/ stats/

# Run tests
test:
	@echo "🧪 Running tests..."
	stack test

# Run with coverage
test-coverage:
	@echo "📊 Running tests with coverage..."
	stack test --coverage

# Run benchmarks
bench:
	@echo "⏱️  Running benchmarks..."
	stack bench

# Run main executable
run:
	@echo "🎮 Running game..."
	stack exec connect-four-exe

# Run GUI
gui:
	@echo "🎨 Launching GUI..."
	stack exec connect-four-exe -- --gui

# Run Terminal UI
tui:
	@echo "💻 Launching TUI..."
	stack exec connect-four-exe -- --tui

# Run single player
single:
	@echo "🤖 Starting single player..."
	stack exec connect-four-exe -- --single

# Run two player
two:
	@echo "👥 Starting two player..."
	stack exec connect-four-exe -- --two

# Run AI demo
ai-demo:
	@echo "🤖 Starting AI demo..."
	stack exec connect-four-exe -- --ai-demo

# Run server
server:
	@echo "🌐 Starting server on port 9160..."
	stack exec connect-four-server

# Run server on custom port
server-port:
	@echo "🌐 Starting server on port $(PORT)..."
	stack exec connect-four-server -- --port $(PORT)

# Run client
client:
	@echo "🔌 Connecting to server..."
	stack exec connect-four-client

# Run client with custom settings
client-connect:
	@echo "🔌 Connecting to $(HOST):$(PORT) as $(NAME)..."
	stack exec connect-four-client -- --host $(HOST) --port $(PORT) --name $(NAME)

# Install dependencies
install:
	@echo "📦 Installing dependencies..."
	stack setup
	stack build --only-dependencies

# Update dependencies
update:
	@echo "🔄 Updating dependencies..."
	stack update

# Generate documentation
docs:
	@echo "📚 Generating documentation..."
	stack haddock --open

# Format code
format:
	@echo "✨ Formatting code..."
	find src -name "*.hs" -exec ormolu --mode inplace {} \;
	find app -name "*.hs" -exec ormolu --mode inplace {} \;
	find test -name "*.hs" -exec ormolu --mode inplace {} \;

# Lint code
lint:
	@echo "🔍 Linting code..."
	hlint src/ app/ test/

# Quick check (format + lint + test)
check: format lint test
	@echo "✅ All checks passed!"

# Development mode (watch for changes)
dev:
	@echo "👀 Starting development mode..."
	stack build --file-watch --fast

# Create release build
release:
	@echo "📦 Creating release build..."
	stack build --copy-bins --local-bin-path ./bin

# Install executables to system
install-exe:
	@echo "📥 Installing executables..."
	stack install

# Show project info
info:
	@echo "ℹ️  Project Information"
	@echo "======================"
	@stack --version
	@stack exec -- ghc --version
	@echo ""
	@echo "Executables:"
	@echo "  - connect-four-exe"
	@echo "  - connect-four-server"
	@echo "  - connect-four-client"

# Help
help:
	@echo "Connect Four - Haskell"
	@echo "===================="
	@echo ""
	@echo "Build Commands:"
	@echo "  make build           - Build the project"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make install         - Install dependencies"
	@echo "  make release         - Create release build"
	@echo ""
	@echo "Run Commands:"
	@echo "  make run             - Run interactive menu"
	@echo "  make gui             - Run GUI"
	@echo "  make tui             - Run Terminal UI"
	@echo "  make single          - Quick single player"
	@echo "  make two             - Quick two player"
	@echo "  make ai-demo         - Watch AI vs AI"
	@echo ""
	@echo "Network Commands:"
	@echo "  make server          - Start server (port 9160)"
	@echo "  make server PORT=8080        - Server on custom port"
	@echo "  make client          - Connect to localhost:9160"
	@echo "  make client HOST=example.com PORT=8080 NAME=Alice"
	@echo ""
	@echo "Development Commands:"
	@echo "  make test            - Run tests"
	@echo "  make bench           - Run benchmarks"
	@echo "  make docs            - Generate documentation"
	@echo "  make format          - Format code"
	@echo "  make lint            - Lint code"
	@echo "  make check           - Format + lint + test"
	@echo "  make dev             - Development mode (watch)"
	@echo ""
	@echo "Other Commands:"
	@echo "  make info            - Show project info"
	@echo "  make help            - Show this help"