# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-XX

### Added
- ✨ Complete Connect Four game implementation
- 🤖 AI opponent with Monte Carlo Tree Search
- ⚡ Parallel AI computation
- 🌐 Multiplayer support via WebSockets
- 🎨 Graphical UI using Gloss
- 💻 Terminal UI using Brick
- 💾 Save/Load game functionality
- 📊 Player statistics and leaderboards
- 🔄 Game replay system
- 🎮 Multiple game modes (Single, Two Player, AI Demo)
- 🧵 Concurrent game session management
- 🔒 Thread-safe operations with STM
- 📝 Chat system in multiplayer
- ⏱️  Move timeout system
- 🔌 Auto-reconnect for clients
- 📈 Performance benchmarks
- 🧪 Comprehensive test suite

### Features Detail

#### Game Engine
- Full Connect Four rules implementation
- Win detection in all 4 directions
- Board validation and move legality
- Undo functionality
- Move history tracking

#### AI System
- Monte Carlo Tree Search algorithm
- 4 difficulty levels (Easy, Medium, Hard, Expert)
- Instant win/block detection
- Parallel evaluation using Haskell strategies
- Configurable simulation count
- Performance benchmarking tools

#### Networking
- WebSocket-based server
- Support for 100+ concurrent games
- Real-time game updates
- Player matching system
- Connection management
- Graceful disconnection handling
- Ping/pong heartbeat

#### User Interfaces
- **Gloss GUI**: Mouse-driven gameplay with animations
- **Brick TUI**: Full-featured terminal interface
- **Console**: Simple text-based fallback
- Menu system for mode selection
- In-game help screens

#### Persistence
- Binary serialization for efficiency
- JSON serialization for readability
- Auto-save every N moves
- Game replay from history
- Player profile management
- Statistics tracking

#### Concurrency
- STM for thread-safe state
- Async for parallel operations
- Resource pooling
- Rate limiting
- Deadlock prevention

### Technical Specifications
- GHC 9.6.7
- Stack/Cabal build system
- Extensive use of STM and Async
- Parallel strategies for AI
- Type-safe protocol definitions
- Property-based testing with QuickCheck

## [Unreleased]

### Planned Features
- [ ] Tournament mode
- [ ] Replay visualization with smooth animations
- [ ] Advanced statistics dashboard
- [ ] Mobile client
- [ ] Neural network AI
- [ ] Spectator mode for live games
- [ ] Cloud deployment scripts
- [ ] Voice chat integration
- [ ] Customizable themes
- [ ] Game recording/streaming

### Known Issues
- Gloss performance on older GPUs
- Windows GLUT installation manual
- AI thinking time not enforced in GUI
- No graceful server shutdown yet

## Development History

### Pre-1.0 Iterations
- Initial prototype with basic game logic
- MCTS AI implementation
- Networking layer development
- UI iterations
- Performance optimization
- Testing and documentation

---

## Version Guide

- **Major version** (X.0.0): Breaking API changes
- **Minor version** (1.X.0): New features, backward compatible
- **Patch version** (1.0.X): Bug fixes, minor improvements