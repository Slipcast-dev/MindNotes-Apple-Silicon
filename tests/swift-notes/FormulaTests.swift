import Foundation

private let price = UUID(), qty = UUID(), name = UUID(), due = UUID(), done = UUID(), note = UUID(), moment = UUID()

private let props: [String: (id: UUID, type: FormulaType)] = [
    "Цена": (price, .number), "Количество": (qty, .number), "Название": (name, .text),
    "Срок": (due, .date), "Готово": (done, .bool), "Заметка": (note, .text), "Время": (moment, .date),
]

private func resolve(_ arg: String) -> (id: UUID, type: FormulaType)? {
    if let p = props[arg] { return p }
    if let id = UUID(uuidString: arg) { return props.values.first { $0.id == id } }
    return nil
}

private let day = LocalDate(year: 2026, month: 3, day: 10)!

private func context(_ values: [UUID: FormulaValue] = [:]) -> FormulaContext {
    var base: [UUID: FormulaValue] = [
        price: .number(250), qty: .number(4), name: .text("Купить коробки"), due: .date(DateValue(start: .day(day))),
        done: .bool(false), note: .empty,
    ]
    for (k, v) in values { base[k] = v }
    return FormulaContext(values: base, today: LocalDate(year: 2026, month: 3, day: 1)!, zone: TimeZone(identifier: "Europe/Moscow")!)
}

private func run(_ source: String, _ values: [UUID: FormulaValue] = [:]) throws -> FormulaValue {
    try FormulaEvaluator.evaluate(try CompiledFormula.compile(source, resolve: resolve), context: context(values))
}

/// Ошибка и место: текст по диапазону ошибки.
private func failure(_ source: String, _ values: [UUID: FormulaValue] = [:]) -> (message: String, at: String)? {
    do { _ = try run(source, values); return nil } catch let e as FormulaError {
        let chars = Array(source)
        let lo = min(e.range.lowerBound, chars.count), hi = min(e.range.upperBound, chars.count)
        return (e.message, String(chars[lo..<hi]))
    } catch { return ("другая ошибка: \(error)", "") }
}

func runFormulaTests() async {
    await test("Формулы: числа, текст, логика, приоритеты") {
        checkEqual(try run("prop(\"Цена\") * prop(\"Количество\")"), .number(1000))
        checkEqual(try run("1 + 2 * 3"), .number(7))
        checkEqual(try run("(1 + 2) * 3"), .number(9))
        checkEqual(try run("2 ^ 3 ^ 2"), .number(512), "степень справа налево")
        checkEqual(try run("-2 ^ 2"), .number(4), "унарный минус сильнее степени")
        checkEqual(try run("10 % 4 + 7 / 2"), .number(5.5))
        checkEqual(try run("1.5e3 + .5"), .number(1500.5))
        checkEqual(try run("\"а\" + \"б\" + 1"), .text("аб1"), "текст склеивается с числом")
        checkEqual(try run("1 < 2 and not (2 < 1) or false"), .bool(true))
        checkEqual(try run("1 < 2 && !(2 < 1) || false"), .bool(true), "символьные формы")
        checkEqual(try run("\"б\" > \"а\""), .bool(true))
        checkEqual(try run("prop(\"Готово\") == false"), .bool(true))
        checkEqual(try run("if(prop(\"Готово\"), \"✓\", \"нет\")"), .text("нет"))
        checkEqual(try run("ifs(prop(\"Цена\") > 500, \"дорого\", prop(\"Цена\") > 100, \"средне\", \"дёшево\")"), .text("средне"))
        checkEqual(try run("ifs(false, 1, false, 2, 3)"), .number(3))
    }

    await test("Формулы: функции чисел и текста") {
        checkEqual(try run("abs(-3) + ceil(1.2) + floor(1.8) + sign(-5)"), .number(5))
        checkEqual(try run("round(2.345, 2)"), .number(2.35))
        checkEqual(try run("round(-2.5)"), .number(-3))
        checkEqual(try run("min(3, 1, 2) + max(3, 1, 2)"), .number(4))
        checkEqual(try run("sqrt(16) + pow(2, 10) + mod(17, 5)"), .number(1030))
        checkEqual(try run("length(\"ёлка🎄\")"), .number(5), "символы, а не байты")
        checkEqual(try run("upper(\"ёж\") + lower(\"ЁЖ\") + trim(\"  x \")"), .text("ЁЖёжx"))
        checkEqual(try run("contains(prop(\"Название\"), \"коробки\")"), .bool(true))
        checkEqual(try run("startsWith(\"Купить\", \"Куп\") and endsWith(\"Купить\", \"ить\")"), .bool(true))
        checkEqual(try run("replace(\"а-а-а\", \"а\", \"б\") + \" \" + replaceAll(\"а-а-а\", \"а\", \"б\")"), .text("б-а-а б-б-б"))
        checkEqual(try run("slice(\"Минерва\", 1, 4)"), .text("ине"))
        checkEqual(try run("slice(\"Минерва\", 3)"), .text("ерва"))
        checkEqual(try run("slice(\"абв\", -5, 99)"), .text("абв"), "границы обрезаются")
        checkEqual(try run("format(3) + format(true)"), .text("3true"))
        checkEqual(try run("toNumber(\"12,5\") * 2"), .number(25))
        checkEqual(try run("empty(toNumber(\"не число\"))"), .bool(true))
        checkEqual(try run("join(\", \", \"а\", prop(\"Заметка\"), \"б\")"), .text("а, б"), "пустые пропускаются")
        checkEqual(try run("\"Строка с \\\"кавычками\\\" и \\\\\""), .text("Строка с \"кавычками\" и \\"))
    }

    await test("Формулы: даты") {
        let d = { (y: Int, m: Int, dd: Int) in FormulaValue.date(DateValue(start: .day(LocalDate(year: y, month: m, day: dd)!))) }
        checkEqual(try run("today()"), d(2026, 3, 1))
        checkEqual(try run("dateAdd(prop(\"Срок\"), 25, \"days\")"), d(2026, 4, 4))
        checkEqual(try run("dateSubtract(prop(\"Срок\"), 1, \"months\")"), d(2026, 2, 10))
        checkEqual(try run("dateAdd(prop(\"Срок\"), 1, \"years\")"), d(2027, 3, 10))
        checkEqual(try run("dateBetween(prop(\"Срок\"), today(), \"days\")"), .number(9))
        checkEqual(try run("dateBetween(today(), prop(\"Срок\"), \"days\")"), .number(-9))
        checkEqual(try run("dateBetween(prop(\"Срок\"), today(), \"weeks\")"), .number(1))
        checkEqual(try run("dateBetween(dateAdd(today(), 40, \"days\"), today(), \"months\")"), .number(1))
        checkEqual(try run("formatDate(prop(\"Срок\"))"), .text("10.03.2026"))
        checkEqual(try run("formatDate(prop(\"Срок\"), \"YYYY-MM-DD\")"), .text("2026-03-10"))
        checkEqual(try run("year(prop(\"Срок\")) * 10000 + month(prop(\"Срок\")) * 100 + day(prop(\"Срок\"))"), .number(20260310))
        checkEqual(try run("weekday(prop(\"Срок\"))"), .number(2), "10 марта 2026 — вторник")
        checkEqual(try run("prop(\"Срок\") > today()"), .bool(true))
        // Диапазон и момент.
        let span = FormulaValue.date(DateValue(start: .day(day), end: .day(LocalDate(year: 2026, month: 3, day: 12)!)))
        checkEqual(try run("dateEnd(prop(\"Срок\"))", [due: span]), d(2026, 3, 12))
        checkEqual(try run("dateStart(dateAdd(prop(\"Срок\"), 1, \"days\"))", [due: span]), d(2026, 3, 11), "диапазон сдвигается целиком")
        let tz = TimeZone(identifier: "Europe/Moscow")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let ms = Int64(cal.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 23, minute: 30))!.timeIntervalSince1970 * 1000)
        let at = FormulaValue.date(DateValue(start: .moment(ms: ms, zone: tz.identifier)))
        checkEqual(try run("formatDate(dateAdd(prop(\"Время\"), 45, \"minutes\"))", [moment: at]), .text("30.03.2026 00:15"))
        checkEqual(try run("dateBetween(dateAdd(prop(\"Время\"), 3, \"hours\"), prop(\"Время\"), \"hours\")", [moment: at]), .number(3))
        checkEqual(try run("formatDate(dateAdd(prop(\"Срок\"), 2, \"hours\"))"), .text("10.03.2026 02:00"), "часы к дню — момент от полуночи")
        // Конец месяца не переполняется.
        checkEqual(try run("dateAdd(prop(\"Срок\"), 1, \"months\")", [due: d(2026, 1, 31)]), d(2026, 2, 28))
    }

    await test("Формулы: пустые значения") {
        checkEqual(try run("prop(\"Цена\") * 2", [price: .empty]), .empty, "арифметика с пустым — пусто")
        checkEqual(try run("empty(prop(\"Заметка\"))"), .bool(true))
        checkEqual(try run("prop(\"Заметка\") + \"!\""), .text("!"), "пустой текст в склейке — пустая строка")
        checkEqual(try run("prop(\"Цена\") > 1", [price: .empty]), .bool(false), "сравнение с пустым — ложь")
        checkEqual(try run("prop(\"Цена\") == prop(\"Количество\")", [price: .empty, qty: .empty]), .bool(true))
        checkEqual(try run("if(prop(\"Готово\"), 1, 2)", [done: .empty]), .number(2), "пустое условие — ложь")
        checkEqual(try run("length(prop(\"Заметка\"))"), .number(0))
        checkEqual(try run("dateAdd(prop(\"Срок\"), 1, \"days\")", [due: .empty]), .empty)
        checkEqual(try run("format(prop(\"Заметка\"))"), .text(""))
        checkEqual(try run("min(prop(\"Цена\"), 5)", [price: .empty]), .number(5), "пустые аргументы min пропускаются")
    }

    await test("Формулы: ошибки с местом") {
        func expect(_ source: String, contains text: String, at place: String, _ values: [UUID: FormulaValue] = [:], file: StaticString = #fileID, line: UInt = #line) {
            guard let f = failure(source, values) else { return check(false, "нет ошибки: \(source)", file: file, line: line) }
            check(f.message.contains(text), "сообщение «\(f.message)» для \(source)", file: file, line: line)
            checkEqual(f.at, place, "место для \(source)", file: file, line: line)
        }
        expect("prop(\"Цена\") + prop(\"Срок\")", contains: "dateAdd", at: "prop(\"Цена\") + prop(\"Срок\")")
        expect("1 + (2 *", contains: "оборвалась", at: "")
        expect("(1 + 2", contains: "закрывающей", at: "(1 + 2")
        expect("prop(\"Нет такого\")", contains: "Нет свойства «Нет такого»", at: "\"Нет такого\"")
        expect("cost * 2", contains: "Неизвестное имя «cost»", at: "cost")
        expect("eval(\"1\")", contains: "Нет функции «eval»", at: "eval(\"1\")")
        expect("1 / 0", contains: "Деление на ноль", at: "1 / 0")
        expect("prop(\"Цена\") / (prop(\"Количество\") - 4)", contains: "Деление на ноль", at: "prop(\"Цена\") / (prop(\"Количество\") - 4)")
        expect("sqrt(-1)", contains: "Корень", at: "sqrt(-1)")
        expect("if(1, 2, 3)", contains: "Ожидалось логическое", at: "1")
        expect("if(true, 1, \"а\")", contains: "одного типа", at: "if(true, 1, \"а\")")
        expect("1 < \"а\"", contains: "разные типы", at: "1 < \"а\"")
        expect("1 < 2 < 3", contains: "цепочкой", at: "<")
        expect("dateAdd(today(), 1, \"дней\")", contains: "«дней»", at: "\"дней\"")
        expect("round(1)  2", contains: "Лишний текст", at: "2")
        expect("\"не закрыта", contains: "кавычкой", at: "\"не закрыта")
        expect("1 # 2", contains: "Недопустимый символ «#»", at: "#")
        expect("abs(1, 2)", contains: "нужно аргументов 1, передано 2", at: "abs(1, 2)")
        expect("prop(1)", contains: "в кавычках", at: "prop(1)")
        expect("", contains: "пуста", at: "")
        expect("pow(10, 400)", contains: "переполнение", at: "pow(10, 400)")
        expect("\"\\q\"", contains: "экранированная", at: "\\q")
    }

    await test("Формулы: пределы длины, вложенности, шагов и текста") {
        let long = String(repeating: "1+", count: 2100) + "1"
        check(failure(long)?.message.contains("длиннее") == true, "длина")
        let deep = String(repeating: "(", count: 70) + "1" + String(repeating: ")", count: 70)
        check(failure(deep)?.message.contains("вложенность") == true, "вложенность")
        let ok = String(repeating: "(", count: 30) + "1" + String(repeating: ")", count: 30)
        checkEqual(try run(ok), .number(1), "умеренная вложенность допустима")
        // Цепочка без скобок растит дерево: 100 слагаемых — можно, 1000 — понятная ошибка, а не падение.
        let wide = (0..<100).map { _ in "1" }.joined(separator: "+")
        checkEqual(try run(wide), .number(100))
        let chain = (0..<1000).map { _ in "1" }.joined(separator: "+")
        check(failure(chain)?.message.contains("слишком сложная") == true, "длинная цепочка")
        // Широкое неглубокое дерево в пределе длины считается.
        let fan = "max(" + (0..<40).map { _ in "max(" + (0..<40).map { _ in "1" }.joined(separator: ",") + ")" }.joined(separator: ",") + ")"
        check(fan.count <= FormulaLimits.maxSource, "в пределе длины: \(fan.count)")
        checkEqual(try run(fan), .number(1), "1641 шаг укладывается")
        // Предел шагов из текста недостижим (длина ограничена), он страхует от повреждённого дерева: проверяется на собранном вручную.
        let huge = FormulaNode.call("max", (0..<12_000).map { .number(Double($0), 0..<1) }, 0..<1)
        do {
            _ = try FormulaEvaluator.evaluate(CompiledFormula(node: huge, type: .number), context: context())
            check(false, "ожидался предел шагов")
        } catch let e as FormulaError { check(e.message.contains("долгое"), e.message) }
        // Текст результата ограничен.
        let doubled = String(repeating: "replaceAll(", count: 20) + "\"ab\"" + String(repeating: ", \"a\", \"aa\")", count: 20)
        check(failure(doubled)?.message.contains("длиннее") == true, "текст результата")
    }

    await test("Формулы: самая глубокая допустимая формула в потоке со стеком 512 КБ") {
        // Пересчёт в приложении идёт на очереди записи: у её потоков стек 512 КБ.
        let terms = FormulaLimits.maxTreeDepth
        let chain = (0..<terms).map { _ in "1" }.joined(separator: "+")
        let nested = String(repeating: "abs(", count: 30) + "-1" + String(repeating: ")", count: 30)
        var results: [Result<FormulaValue, Error>] = []
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            for source in [chain, nested] { results.append(Result { try run(source) }) }
            finished.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        finished.wait()
        checkEqual(results.count, 2)
        checkEqual(try results[0].get(), .number(Double(terms)))
        checkEqual(try results[1].get(), .number(1))
    }

    await test("Формулы: ссылки хранятся по ID, переименование не ломает") {
        let source = "prop(\"Цена\") * prop(\"Количество\") + length(\"prop(\\\"Цена\\\")\")"
        let stored = try FormulaReferences.toStorage(source, names: ["Цена": price, "Количество": qty])
        check(stored.contains(price.uuidString) && stored.contains(qty.uuidString), "ID в тексте: \(stored)")
        check(stored.contains("length(\"prop(\\\"Цена\\\")\")"), "строка внутри не тронута")
        let compiled = try CompiledFormula.compile(stored, resolve: resolve)
        checkEqual(compiled.dependencies, [price, qty])
        checkEqual(compiled.type, .number)
        // Свойство переименовали: показ берёт новое имя.
        let shown = try FormulaReferences.toDisplay(stored, names: [price: "Стоимость", qty: "Штук \"шт\""])
        checkEqual(shown, "prop(\"Стоимость\") * prop(\"Штук \\\"шт\\\"\") + length(\"prop(\\\"Цена\\\")\")")
        checkEqual(try FormulaReferences.toDisplay(try FormulaReferences.toStorage(shown, names: ["Стоимость": price, "Штук \"шт\"": qty]), names: [price: "Стоимость", qty: "Штук \"шт\""]), shown, "круговой проход")
        // Удалённое свойство: ID остаётся в тексте и даёт понятную ошибку.
        let orphan = "prop(\"\(UUID().uuidString)\") + 1"
        check(failure(orphan)?.message.contains("Нет свойства") == true, "удалённое свойство")
    }

    await test("Формулы: находки ревью безопасности не роняют вычисление") {
        // Огромные числа там, где нужно целое.
        check(failure("round(1, 1e19)")?.message.contains("знаков") == true, "round с огромным числом знаков")
        check(failure("round(1, pow(10, 300))")?.message.contains("знаков") == true)
        checkEqual(try run("slice(\"abc\", 1e19)"), .text(""))
        checkEqual(try run("slice(\"abc\", 0, -1e300)"), .text(""))
        checkEqual(try run("slice(\"abc\", -1e300, 1e300)"), .text("abc"))
        // Рост строки считается до замены.
        let big = String(repeating: "a", count: 40_000)
        check(failure("replaceAll(prop(\"Заметка\"), \"a\", \"aa\")", [note: .text(big)])?.message.contains("длиннее") == true, "replaceAll заранее")
        check(failure("length(prop(\"Заметка\"))", [note: .text(String(repeating: "я", count: FormulaLimits.maxText + 1))])?.message.contains("свойства длиннее") == true)
        // Даты из повреждённых данных и выход за годы 1…9999.
        let extreme = FormulaValue.date(DateValue(start: .moment(ms: Int64.max, zone: "UTC")))
        checkEqual(try run("dateBetween(prop(\"Время\"), prop(\"Срок\"), \"hours\")", [moment: extreme]), .empty, "невозможная дата — пусто")
        checkEqual(FormulaValue.from(.time(Int64.min), property: PropertyDefinition(id: UUID(), databaseID: UUID(), name: "x", type: .createdTime, sortKey: "a")), .empty)
        check(failure("dateAdd(today(), 1000000, \"years\")")?.message.contains("диапазона") == true, "год больше 9999")
        let first = FormulaValue.date(DateValue(start: .day(LocalDate(year: 1, month: 1, day: 5)!)))
        check(failure("dateSubtract(prop(\"Срок\"), 10, \"days\")", [due: first])?.message.contains("диапазона") == true, "раньше 1 года")
        check(failure("dateAdd(prop(\"Срок\"), 1000000, \"minutes\")", [due: .date(DateValue(start: .day(LocalDate(year: 9999, month: 12, day: 31)!)))])?.message.contains("диапазона") == true)
        // Ссылка только прямой записью и сообщение о минимуме аргументов.
        check(failure("prop((\"Цена\"))")?.message.contains("в кавычках") == true, "prop в скобках")
        check(failure("min()")?.message.contains("не меньше 1") == true, failure("min()")?.message ?? "")
        // Имя с ударением в начале переживает хранение и показ.
        let accent = "\u{301}Цена"
        let stored = try FormulaReferences.toStorage("prop(\"Цена\")", names: ["Цена": price])
        let shown = try FormulaReferences.toDisplay(stored, names: [price: accent])
        check(shown.contains("\\u{301}"), "знак экранирован: \(shown)")
        let back = try FormulaReferences.toStorage(shown, names: [accent: price])
        checkEqual(back, stored, "круговой проход с ударением")
        checkEqual(try run("\"\\u{44F}\""), .text("я"), "экранирование \\u{…}")
        check(failure("\"\\u{110000}\"")?.message.contains("экранированная") == true)
    }

    await test("Формулы: поиск циклов в графе зависимостей") {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let edges: [UUID: Set<UUID>] = [a: [b], b: [c, d], c: [a], d: []]
        checkEqual(DependencyGraph.cycle(from: a, edges: { edges[$0] ?? [] }), [a, b, c, a])
        checkEqual(DependencyGraph.cycle(from: d, edges: { edges[$0] ?? [] }), nil)
        checkEqual(DependencyGraph.cycle(from: a, edges: { $0 == a ? [a] : [] }), [a, a], "ссылка на себя")
        // Цикл, не проходящий через начало, не мешает: формулу это не касается.
        let other: [UUID: Set<UUID>] = [a: [b], b: [c], c: [b]]
        checkEqual(DependencyGraph.cycle(from: a, edges: { other[$0] ?? [] }), nil)
        // Цикл в данных из копии находится, даже если не проходит через проверяемое свойство.
        checkEqual(DependencyGraph.anyCycle(in: [a, b, c], edges: { other[$0] ?? [] }), [b, c, b])
        // Длинная цепочка без рекурсии: 100 000 свойств не исчерпывают стек.
        let chain = (0..<100_000).map { _ in UUID() }
        var next: [UUID: Set<UUID>] = [:]
        for i in 0..<(chain.count - 1) { next[chain[i]] = [chain[i + 1]] }
        checkEqual(DependencyGraph.cycle(from: chain[0], edges: { next[$0] ?? [] }), nil)
        next[chain[chain.count - 1]] = [chain[0]]
        checkEqual(DependencyGraph.cycle(from: chain[0], edges: { next[$0] ?? [] })?.count, chain.count + 1)
    }

    await test("Формулы: случайный ввод не роняет разбор и укладывается в пределы") {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["prop(\"Цена\")", "prop(\"Название\")", "1", "2.5", "\"т\"", "(", ")", ",", "+", "-", "*", "/", "^", "%", "<", "==", "and", "or",
                      "not", "if(", "ifs(", "today()", "dateAdd(", "\"days\"", "abs(", "round(", "length(", "true", " ", "\\", "\"", "#", "ё", "🎄", "e9"]
        var parsed = 0, failed = 0
        let start = Date()
        for _ in 0..<3000 {
            let n = Int.random(in: 1...40, using: &rng)
            let source = (0..<n).map { _ in pieces.randomElement(using: &rng)! }.joined()
            do { _ = try run(source); parsed += 1 } catch is FormulaError { failed += 1 } catch { check(false, "не FormulaError: \(source)") }
        }
        check(parsed + failed == 3000, "всё обработано")
        // Синтаксически верные выражения случайной формы: проверка типов и вычисление тоже не падают.
        func gen(_ depth: Int) -> String {
            let leaves = ["prop(\"Цена\")", "prop(\"Количество\")", "prop(\"Название\")", "prop(\"Срок\")", "prop(\"Готово\")", "prop(\"Заметка\")",
                          "0", "1", "-3.5", "\"т\"", "\"\"", "true", "false", "today()"]
            guard depth > 0, Int.random(in: 0...3, using: &rng) > 0 else { return leaves.randomElement(using: &rng)! }
            let ops = ["+", "-", "*", "/", "%", "^", "==", "!=", "<", ">=", "and", "or"]
            switch Int.random(in: 0...3, using: &rng) {
            case 0: return "(\(gen(depth - 1)) \(ops.randomElement(using: &rng)!) \(gen(depth - 1)))"
            case 1: return "not \(gen(depth - 1))"
            case 2:
                let f = FormulaFunctions.all.filter { $0.name != "prop" }.randomElement(using: &rng)!.name
                return "\(f)(" + (0..<Int.random(in: 0...3, using: &rng)).map { _ in gen(depth - 1) }.joined(separator: ", ") + ")"
            default: return "if(\(gen(depth - 1)), \(gen(depth - 1)), \(gen(depth - 1)))"
            }
        }
        var valid = 0, rejected = 0
        for _ in 0..<5000 {
            let source = gen(5)
            do { _ = try run(source); valid += 1 } catch is FormulaError { rejected += 1 } catch { check(false, "не FormulaError: \(source)") }
        }
        check(valid > 100, "часть случайных формул вычисляется: \(valid)")
        print("фаззинг грамматикой: вычислено \(valid), отклонено \(rejected)")
        check(Date().timeIntervalSince(start) < 20, "без зависаний")
        print("фаззинг: разобрано \(parsed), ошибок \(failed)")
    }

    await test("Формулы: значение свойства как вход") {
        let opts = [PropertyOption(id: UUID(), name: "Срочно", sortKey: "a")]
        func def(_ type: PropertyType, _ config: PropertyConfig = PropertyConfig()) -> PropertyDefinition {
            PropertyDefinition(id: UUID(), databaseID: UUID(), name: "x", type: type, sortKey: "a", options: opts, config: config)
        }
        checkEqual(FormulaValue.from(.number(3), property: def(.number)), .number(3))
        checkEqual(FormulaValue.from(nil, property: def(.checkbox)), .bool(false), "пустой флажок — ложь")
        checkEqual(FormulaValue.from(.options([opts[0].id]), property: def(.select)), .text("Срочно"))
        checkEqual(FormulaValue.from(.relation([LinkedPage(id: UUID(), title: "А"), LinkedPage(id: UUID(), title: "Б")]), property: def(.relation)), .text("А, Б"))
        checkEqual(FormulaValue.from(.unconverted("abc"), property: def(.number)), .empty)
        checkEqual(FormulaValue.from(.text(""), property: def(.text)), .empty)
        checkEqual(FormulaType.of(def(.rollup, .rollup(relation: UUID(), property: UUID(), aggregate: .sum))), .number)
        checkEqual(FormulaType.of(def(.editedTime)), .date)
        checkEqual(FormulaFunctions.names.count, FormulaFunctions.all.count, "имена функций не повторяются")
    }
}
