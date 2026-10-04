import Foundation

struct ATVVAudioSession {
    private(set) var ready = false
    private(set) var streaming = false
    private(set) var frameSize = 120
    private(set) var sessionID: UInt8 = 0
    private var pending = Data()
    private var predictor = 0
    private var index = 0
    private static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    private static let changes = [-1,-1,-1,-1,2,4,6,8]

    /// Accept only negotiated ATVV v1, ADPCM 16k. The firmware-2671 swapped
    /// capability layout is accepted only when its codec byte is zero.
    mutating func control(_ data: Data) -> Bool {
        let b = Array(data)
        guard let code = b.first else { return false }
        switch code {
        case 0x0B:
            ready = false
            streaming = false
            pending.removeAll()
            guard b.count >= 9, b[1] == 1, b[2] == 0 else { return false }
            let codecs = b[3] == 0 ? b[4] : b[3]
            let size = Int(b[5]) << 8 | Int(b[6])
            guard codecs & 2 != 0, size > 0, size <= 512 else { return false }
            frameSize = size
            ready = true
        case 0x04:
            guard ready, b.count >= 4, b[2] == 2 else {
                streaming = false
                pending.removeAll()
                return false
            }
            sessionID = b[3]
            streaming = true
            predictor = 0
            index = 0
            pending.removeAll()
        case 0x00:
            streaming = false
            pending.removeAll()
        case 0x0A:
            guard ready, streaming, b.count >= 7, b[1] == 2, b[6] <= 88 else { return false }
            predictor = Int(Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5])))
            index = Int(b[6])
            pending.removeAll()
        default: return false
        }
        return true
    }

    mutating func audio(_ data: Data) -> [Int16] {
        guard ready, streaming else { return [] }
        pending.append(data)
        var samples: [Int16] = []
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            for byte in frame {
                samples.append(decode(Int(byte >> 4)))
                samples.append(decode(Int(byte & 15)))
            }
        }
        return samples
    }

    private mutating func decode(_ nibble: Int) -> Int16 {
        let step = Self.steps[index]
        var delta = step >> 3
        if nibble & 1 != 0 { delta += step >> 2 }
        if nibble & 2 != 0 { delta += step >> 1 }
        if nibble & 4 != 0 { delta += step }
        predictor = min(32767, max(-32768, predictor + (nibble & 8 == 0 ? delta : -delta)))
        index = min(88, max(0, index + Self.changes[nibble & 7]))
        return Int16(predictor)
    }
}
