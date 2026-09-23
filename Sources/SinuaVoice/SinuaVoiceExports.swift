// VoiceSource, VoiceOverrides and AgentState live in SinuaVoiceTypes (no audio I/O), so
// the Sinua views can take them without linking the microphone code in this module.
// Re-exported here so every `import SinuaVoice` keeps seeing them unchanged.
@_exported import SinuaVoiceTypes
