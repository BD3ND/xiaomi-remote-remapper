import Foundation

func voiceAudioTests() -> [String] {
    var failures: [String] = []
    var session = ATVVAudioSession()
    if !session.audio(Data([0x77])).isEmpty { failures.append("audio accepted before negotiation") }
    _ = session.control(Data([0x0B, 1, 0, 2, 3, 0, 2, 0, 0]))
    if !session.ready || session.frameSize != 2 { failures.append("16k capabilities not negotiated") }
    _ = session.control(Data([4, 2, 2, 7]))
    if !session.streaming || session.sessionID != 7 { failures.append("physical direct stream rejected") }
    _ = session.control(Data([0x0A, 2, 0, 0, 0, 0, 0]))
    if !session.audio(Data([0x70])).isEmpty { failures.append("partial frame decoded early") }
    if session.audio(Data([0x00])) != [11, 13, 14, 15] { failures.append("IMA high-first vector mismatch") }
    _ = session.control(Data([0, 2]))
    if session.streaming || !session.audio(Data([0x77, 0x77])).isEmpty { failures.append("audio continued after stop") }
    _ = session.control(Data([4, 2, 2, 8]))
    if session.audio(Data([0, 0])) != [0, 0, 0, 0] { failures.append("decoder state leaked across sessions") }
    var invalid = ATVVAudioSession()
    _ = invalid.control(Data([0x0B, 1, 0, 1, 3, 0, 120, 0, 0]))
    if invalid.ready { failures.append("8k codec accepted as 16k") }
    var swapped = ATVVAudioSession()
    _ = swapped.control(Data([0x0B, 1, 0, 0, 3, 0, 120, 0, 0]))
    if !swapped.ready { failures.append("2671 capability layout unsupported") }
    return failures
}
