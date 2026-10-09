import Accelerate
import Foundation
import Synchronization

/// 点阵签名的表达式：一行算式，每帧按格求值，结果截到 −1 到 1。语法与 kited 的 emblem-expression.ts 一致，改动须两边同步。
/// 解析时编译成一串后缀指令。每帧整片图案按批求值（evaluate(batch:)）：每条指令对所有格子调用一次 vDSP / vForce，
/// 逐格解释指令的开销摊到整批上；逐格的 evaluate 只给图形盖住的少数格子用。
nonisolated struct DotExpression: Sendable {
    /// 求值时能读到的量，顺序即 Scope 与着色器里的下标。v 是声音的响度（0～1），音源接入前恒为 0。
    enum Variable: Int, CaseIterable, Sendable {
        case t, x, y, i, w, h, r, a, px, py, d, k, v
    }

    /// 一格的变量值，按 Variable 的顺序。
    struct Scope {
        var values = [Double](repeating: 0, count: Variable.allCases.count)
        subscript(_ variable: Variable) -> Double {
            get { values[variable.rawValue] }
            set { values[variable.rawValue] = newValue }
        }
    }

    enum Op: Sendable {
        case constant, variable
        case negate, not, sin, cos, tan, abs, floor, ceil, round, sqrt, exp, log, sign, fract
        case add, subtract, multiply, divide, modulo, power, less, greater, lessEqual, greaterEqual, equal, notEqual, and, or
        case min, max, hypot, atan2
        case select, clamp, mix, noise

        /// 从栈上取几个数；constant 和 variable 不取、压入一个。
        var arity: Int {
            switch self {
            case .constant, .variable: 0
            case .negate, .not, .sin, .cos, .tan, .abs, .floor, .ceil, .round, .sqrt, .exp, .log, .sign, .fract: 1
            case .select, .clamp, .mix, .noise: 3
            default: 2
            }
        }
    }

    struct Instruction: Sendable {
        let op: Op
        /// constant 的值或 variable 的下标。
        var operand = 0.0
    }

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let maxLength = 240
    private static let maxNodes = 160

    let source: String
    let instructions: [Instruction]
    /// 求值时栈最深压几个数。
    let stackDepth: Int

    init(_ source: String) throws {
        guard source.count <= Self.maxLength else { throw ParseError(message: "表达式不能超过 \(Self.maxLength) 个字符") }
        var parser = Parser(tokens: try Self.tokenize(source))
        guard !parser.tokens.isEmpty else { throw ParseError(message: "表达式为空") }
        instructions = try parser.parse()
        stackDepth = parser.maxDepth
        self.source = source
    }

    /// 解析过的表达式按原文记下：头像随视图刷新反复取同一行算式，不必每次重新解析。
    private static let parsed = Mutex<[String: DotExpression]>([:])

    /// 同 init，解析过的直接取；无效时为 nil。
    static func cached(_ source: String) -> DotExpression? {
        if let hit = parsed.withLock({ $0[source] }) { return hit }
        guard let expression = try? DotExpression(source) else { return nil }
        parsed.withLock { cache in
            // 编辑签名时每改一个字就是一行新算式，攒多了清空重来
            if cache.count >= 64 { cache.removeAll() }
            cache[source] = expression
        }
        return expression
    }

    /// 非有限数按 0。
    func evaluate(_ scope: Scope) -> Double {
        let value = withUnsafeTemporaryAllocation(of: Double.self, capacity: stackDepth) { stack in
            var top = 0
            for instruction in instructions {
                switch instruction.op {
                case .constant: stack[top] = instruction.operand
                case .variable: stack[top] = scope.values[Int(instruction.operand)]
                default:
                    let arity = instruction.op.arity
                    top -= arity
                    stack[top] = Self.apply(instruction.op, stack[top], arity > 1 ? stack[top + 1] : 0, arity > 2 ? stack[top + 2] : 0)
                }
                top += 1
            }
            return stack[0]
        }
        return value.isFinite ? min(max(value, -1), 1) : 0
    }

    /// 一批格子一起求值，结果与逐格的 evaluate 相同。variables 按 Variable 的顺序，每个变量 count 个数，结果按同样的顺序排；
    /// 各格都一样的变量只给一个数。
    func evaluate(batch variables: [ArraySlice<Double>], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var stack = [Double](repeating: 0, count: stackDepth * count)
        stack.withUnsafeMutableBufferPointer { memory in
            func slot(_ index: Int) -> UnsafeMutableBufferPointer<Double> {
                UnsafeMutableBufferPointer(rebasing: memory[index * count ..< (index + 1) * count])
            }
            let none = UnsafeMutableBufferPointer<Double>(start: nil, count: 0)
            var top = 0
            for instruction in instructions {
                switch instruction.op {
                case .constant: slot(top).update(repeating: instruction.operand)
                case .variable:
                    let values = variables[Int(instruction.operand)]
                    if values.count == 1 { slot(top).update(repeating: values[values.startIndex]) }
                    else { values.withUnsafeBufferPointer { _ = slot(top).update(fromContentsOf: $0) } }
                default:
                    let arity = instruction.op.arity
                    top -= arity
                    Self.apply(batch: instruction.op, slot(top), arity > 1 ? slot(top + 1) : none, arity > 2 ? slot(top + 2) : none)
                }
                top += 1
            }
        }
        var result = Array(stack[0..<count])
        for index in result.indices {
            let value = result[index]
            result[index] = value.isFinite ? min(max(value, -1), 1) : 0
        }
        return result
    }

    /// 整批执行一条指令，结果写回 a；b、c 是用完即弃的栈位，可以当草稿用。
    private static func apply(batch op: Op, _ a: UnsafeMutableBufferPointer<Double>,
                              _ b: UnsafeMutableBufferPointer<Double>, _ c: UnsafeMutableBufferPointer<Double>) {
        var a = a, b = b
        switch op {
        case .negate: vDSP.negative(a, result: &a)
        case .abs: vDSP.absolute(a, result: &a)
        case .sin: vForce.sin(a, result: &a)
        case .cos: vForce.cos(a, result: &a)
        case .tan: vForce.tan(a, result: &a)
        case .floor: vForce.floor(a, result: &a)
        case .ceil: vForce.ceil(a, result: &a)
        case .sqrt: vForce.sqrt(a, result: &a)
        case .exp: vForce.exp(a, result: &a)
        case .log: vForce.log(a, result: &a)
        case .add: vDSP.add(a, b, result: &a)
        case .subtract: vDSP.subtract(a, b, result: &a)
        case .multiply: vDSP.multiply(a, b, result: &a)
        case .divide: vDSP.divide(a, b, result: &a)
        case .power: vForce.pow(bases: a, exponents: b, result: &a)
        case .min: vDSP.minimum(a, b, result: &a)
        case .max: vDSP.maximum(a, b, result: &a)
        case .hypot: vDSP.hypot(a, b, result: &a)
        case .atan2: vForce.atan2(x: b, y: a, result: &a)
        case .clamp:
            vDSP.maximum(a, b, result: &a)
            vDSP.minimum(a, c, result: &a)
        case .mix:
            vDSP.subtract(b, a, result: &b)
            vDSP.multiply(b, c, result: &b)
            vDSP.add(a, b, result: &a)
        case .noise: noise(batch: a, b, c)
        // 其余在签名里少见，逐格算。
        default:
            for index in a.indices {
                a[index] = apply(op, a[index], b.isEmpty ? 0 : b[index], c.isEmpty ? 0 : c[index])
            }
        }
    }

    private static func apply(_ op: Op, _ a: Double, _ b: Double, _ c: Double) -> Double {
        switch op {
        case .constant, .variable: 0
        case .negate: -a
        case .not: a == 0 ? 1 : 0
        case .sin: Foundation.sin(a)
        case .cos: Foundation.cos(a)
        case .tan: Foundation.tan(a)
        case .abs: Swift.abs(a)
        case .floor: a.rounded(.down)
        case .ceil: a.rounded(.up)
        // 与 JavaScript 的 Math.round 一致：.5 向正无穷取整
        case .round: (a + 0.5).rounded(.down)
        case .sqrt: Foundation.sqrt(a)
        case .exp: Foundation.exp(a)
        case .log: Foundation.log(a)
        case .sign: a > 0 ? 1 : a < 0 ? -1 : 0
        case .fract: a - a.rounded(.down)
        case .add: a + b
        case .subtract: a - b
        case .multiply: a * b
        case .divide: a / b
        case .modulo: a - b * (a / b).rounded(.down)
        case .power: Foundation.pow(a, b)
        case .less: a < b ? 1 : 0
        case .greater: a > b ? 1 : 0
        case .lessEqual: a <= b ? 1 : 0
        case .greaterEqual: a >= b ? 1 : 0
        case .equal: a == b ? 1 : 0
        case .notEqual: a != b ? 1 : 0
        case .and: a != 0 && b != 0 ? 1 : 0
        case .or: a != 0 || b != 0 ? 1 : 0
        case .min: Swift.min(a, b)
        case .max: Swift.max(a, b)
        case .hypot: Foundation.hypot(a, b)
        case .atan2: Foundation.atan2(a, b)
        // 表达式没有副作用，两支都算好再选，整批求值也这样
        case .select: a != 0 ? b : c
        case .clamp: Swift.min(Swift.max(a, b), c)
        case .mix: a + (b - a) * c
        case .noise: noise(a, b, c)
        }
    }

    // MARK: 词法

    private static func tokenize(_ source: String) throws -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { index += 1; continue }
            if c.isASCII && (c.isNumber || (c == "." && index + 1 < characters.count && characters[index + 1].isNumber)) {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber || characters[end] == "." { end += 1 }
                // 指数部分
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var probe = end + 1
                    if probe < characters.count, characters[probe] == "+" || characters[probe] == "-" { probe += 1 }
                    if probe < characters.count, characters[probe].isASCII, characters[probe].isNumber {
                        end = probe
                        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                    }
                }
                tokens.append(String(characters[index..<end]))
                index = end
                continue
            }
            if c.isASCII && (c.isLetter || c == "_") {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                tokens.append(String(characters[index..<end]).lowercased())
                index = end
                continue
            }
            if index + 1 < characters.count {
                let pair = String(characters[index...index + 1])
                if ["<=", ">=", "==", "!=", "&&", "||"].contains(pair) { tokens.append(pair); index += 2; continue }
            }
            guard "-+*/%^()<>!?:,".contains(c) else { throw ParseError(message: "第 \(index + 1) 个字符无法识别") }
            tokens.append(String(c))
            index += 1
        }
        return tokens
    }

    // MARK: 语法

    /// 递归下降，边读边按后缀顺序写出指令，同时记下求值栈最深压几个数。
    private struct Parser {
        let tokens: [String]
        var index = 0
        var nodes = 0
        var code: [Instruction] = []
        var depth = 0
        var maxDepth = 0

        mutating func parse() throws -> [Instruction] {
            try expression()
            if index < tokens.count { throw ParseError(message: "多余的「\(tokens[index])」") }
            return code
        }

        private var peek: String? { index < tokens.count ? tokens[index] : nil }

        @discardableResult
        private mutating func take(_ expected: String? = nil) throws -> String {
            guard let token = peek else { throw ParseError(message: "表达式不完整") }
            if let expected, token != expected { throw ParseError(message: "应为「\(expected)」，实际是「\(token)」") }
            index += 1
            return token
        }

        private mutating func count() throws {
            nodes += 1
            if nodes > DotExpression.maxNodes { throw ParseError(message: "表达式过于复杂") }
        }

        private mutating func emit(_ op: Op, _ operand: Double = 0) throws {
            code.append(Instruction(op: op, operand: operand))
            depth += op.arity == 0 ? 1 : 1 - op.arity
            maxDepth = Swift.max(maxDepth, depth)
        }

        private mutating func expression() throws {
            try or()
            guard peek == "?" else { return }
            try take()
            try expression()
            try take(":")
            try expression()
            try count()
            try emit(.select)
        }

        private mutating func or() throws {
            try binary(next: { try $0.and() }, ops: ["||": .or])
        }
        private mutating func and() throws {
            try binary(next: { try $0.comparison() }, ops: ["&&": .and])
        }
        private mutating func comparison() throws {
            try binary(next: { try $0.sum() }, ops: ["<": .less, ">": .greater, "<=": .lessEqual, ">=": .greaterEqual,
                                                     "==": .equal, "!=": .notEqual])
        }
        private mutating func sum() throws {
            try binary(next: { try $0.product() }, ops: ["+": .add, "-": .subtract])
        }
        private mutating func product() throws {
            try binary(next: { try $0.unary() }, ops: ["*": .multiply, "/": .divide, "%": .modulo])
        }

        private mutating func binary(next: (inout Parser) throws -> Void, ops: [String: Op]) throws {
            try next(&self)
            while let token = peek, let op = ops[token] {
                try take()
                try next(&self)
                try count()
                try emit(op)
            }
        }

        private mutating func unary() throws {
            if let token = peek, ["-", "+", "!"].contains(token) {
                try take()
                try unary()
                try count()
                switch token {
                case "-": try emit(.negate)
                case "!": try emit(.not)
                default: break
                }
                return
            }
            try power()
        }

        private mutating func power() throws {
            try primary()
            guard peek == "^" else { return }
            try take()
            try unary()
            try count()
            try emit(.power)
        }

        private mutating func primary() throws {
            let token = try take()
            if token == "(" {
                try expression()
                try take(")")
                return
            }
            try count()
            if let first = token.first, first.isNumber || first == "." {
                guard let value = Double(token) else { throw ParseError(message: "数字「\(token)」无效") }
                try emit(.constant, value)
                return
            }
            if peek == "(" {
                try take("(")
                var arguments = 0
                if peek != ")" {
                    try expression()
                    arguments += 1
                    while peek == "," {
                        try take()
                        try expression()
                        arguments += 1
                    }
                }
                try take(")")
                try call(token, arguments: arguments)
                return
            }
            switch token {
            case "pi": try emit(.constant, .pi)
            case "tau": try emit(.constant, 2 * .pi)
            default:
                guard let variable = Variable.allCases.first(where: { "\($0)" == token }) else {
                    throw ParseError(message: "不支持变量 \(token)")
                }
                try emit(.variable, Double(variable.rawValue))
            }
        }

        private static let functions: [String: (arities: [Int], op: Op)] = [
            "sin": ([1], .sin), "cos": ([1], .cos), "tan": ([1], .tan), "abs": ([1], .abs), "floor": ([1], .floor),
            "ceil": ([1], .ceil), "round": ([1], .round), "sqrt": ([1], .sqrt), "exp": ([1], .exp), "log": ([1], .log),
            "sign": ([1], .sign), "fract": ([1], .fract), "min": ([2], .min), "max": ([2], .max), "pow": ([2], .power),
            "hypot": ([2], .hypot), "atan2": ([2], .atan2), "mod": ([2], .modulo), "clamp": ([3], .clamp), "mix": ([3], .mix),
            "noise": ([2, 3], .noise),
        ]

        /// 参数已经按顺序压栈；noise 只给两个参数时第三个按 0。
        private mutating func call(_ name: String, arguments: Int) throws {
            guard let function = Self.functions[name] else { throw ParseError(message: "不支持函数 \(name)") }
            guard function.arities.contains(arguments) else { throw ParseError(message: "函数 \(name) 的参数个数不对") }
            if arguments < function.op.arity { try emit(.constant, 0) }
            try emit(function.op)
        }
    }

    /// noise 的整批版本，结果写回 x，运算次序与逐格版相同，结果一致。
    private static func noise(batch x: UnsafeMutableBufferPointer<Double>, _ y: UnsafeMutableBufferPointer<Double>,
                              _ z: UnsafeMutableBufferPointer<Double>) {
        let ix = vForce.floor(x), iy = vForce.floor(y), iz = vForce.floor(z)
        func smooth(_ v: [Double]) -> [Double] { vDSP.multiply(vDSP.multiply(v, v), vDSP.add(3, vDSP.multiply(-2, v))) }
        let fx = smooth(vDSP.subtract(x, ix)), fy = smooth(vDSP.subtract(y, iy)), fz = smooth(vDSP.subtract(z, iz))
        func hash(_ dx: Double, _ dy: Double, _ dz: Double) -> [Double] {
            var value = vDSP.add(vDSP.add(vDSP.multiply(127.1, vDSP.add(dx, ix)), vDSP.multiply(311.7, vDSP.add(dy, iy))),
                                 vDSP.multiply(74.7, vDSP.add(dz, iz)))
            vForce.sin(value, result: &value)
            vDSP.multiply(43758.5453, value, result: &value)
            return vDSP.subtract(value, vForce.floor(value))
        }
        func lerp(_ a: [Double], _ b: [Double], _ t: [Double]) -> [Double] { vDSP.add(a, vDSP.multiply(vDSP.subtract(b, a), t)) }
        func layer(_ dz: Double) -> [Double] { lerp(lerp(hash(0, 0, dz), hash(1, 0, dz), fx), lerp(hash(0, 1, dz), hash(1, 1, dz), fx), fy) }
        var x = x
        vDSP.add(-1, vDSP.multiply(2, lerp(layer(0), layer(1), fz)), result: &x)
    }

    /// 三维值噪声，输出 −1 到 1，与 kited 的 emblemNoise 相同。
    static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        func fract(_ v: Double) -> Double { v - v.rounded(.down) }
        func hash(_ x: Double, _ y: Double, _ z: Double) -> Double { fract(sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453) }
        func smooth(_ v: Double) -> Double { v * v * (3 - 2 * v) }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let ix = x.rounded(.down), iy = y.rounded(.down), iz = z.rounded(.down)
        let fx = smooth(x - ix), fy = smooth(y - iy), fz = smooth(z - iz)
        func layer(_ zz: Double) -> Double {
            lerp(lerp(hash(ix, iy, zz), hash(ix + 1, iy, zz), fx), lerp(hash(ix, iy + 1, zz), hash(ix + 1, iy + 1, zz), fx), fy)
        }
        return lerp(layer(iz), layer(iz + 1), fz) * 2 - 1
    }
}
