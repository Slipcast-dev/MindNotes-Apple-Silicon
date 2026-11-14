import Foundation

/// Каталог готовых шаблонов. Подписи на языке интерфейса: шаблон, установленный в английском интерфейсе,
/// получает английские названия свойств, вариантов и записей.
enum TemplateCatalog {
    static func title(_ category: CatalogTemplate.Category) -> String {
        switch category {
        case .personal: return L("Личное")
        case .work: return L("Работа")
        case .projects: return L("Проекты")
        case .study: return L("Учёба")
        }
    }

    static func symbol(_ category: CatalogTemplate.Category) -> String {
        switch category {
        case .personal: return "heart"
        case .work: return "briefcase"
        case .projects: return "map"
        case .study: return "graduationcap"
        }
    }

    static var all: [CatalogTemplate] {
        [habitTracker, readingList, goals, travel, roadmap, projectSchedule, tasks, crm, jobApplications, coursePlanner]
    }

    private static func o(_ name: String, _ color: String? = nil) -> CatalogOption { CatalogOption(name: name, color: color) }

    // MARK: Личное

    static var habitTracker: CatalogTemplate {
        let day = L("День"), date = L("Дата"), run = L("Бег"), meditation = L("Медитация"), sleep = L("Сон 7+ ч"), journal = L("Дневник")
        let weekdays = [L("Понедельник"), L("Вторник"), L("Среда"), L("Четверг"), L("Пятница"), L("Суббота"), L("Воскресенье")]
        let today = LocalDate(date: Date(), in: .current)
        let pattern: [[Bool]] = [[true, true, false, true], [true, true, false, false], [false, false, true, true], [false, true, false, false],
                                 [true, true, true, false], [false, true, true, true], [false, true, false, true]]
        let records = (0..<7).map { i -> CatalogRecord in
            let d = today.adding(days: -i)
            let flags = pattern[i]
            return CatalogRecord(key: "d\(i)", title: weekdays[d.weekdayFromMonday],
                                 values: [date: .day(-i), run: .checkbox(flags[0]), meditation: .checkbox(flags[1]),
                                          sleep: .checkbox(flags[2]), journal: .checkbox(flags[3])])
        }
        let checks = [run, meditation, sleep, journal]
        return CatalogTemplate(
            id: "habit-tracker", category: .personal, title: L("Трекер привычек"),
            detail: L("Отмечайте привычки каждый день; под столбцами — процент выполнения"), icon: "👟",
            databases: [CatalogDatabase(
                key: "habits", title: L("Трекер привычек"), titleProperty: day,
                properties: [.plain(date, .date)] + checks.map { .plain($0, .checkbox) },
                views: [CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind,
                                    calculations: Dictionary(uniqueKeysWithValues: checks.map { ($0, RollupAggregate.percentChecked) }).merging([day: .count]) { a, _ in a },
                                    sorts: [(date, true)]),
                        CatalogView(name: L("Календарь"), kind: DatabaseView.calendarKind, dateProperty: date)],
                records: records)])
    }

    static var readingList: CatalogTemplate {
        let name = L("Название"), author = L("Автор"), status = L("Статус"), rating = L("Оценка"), genre = L("Жанр"), finished = L("Дочитано")
        let want = L("Хочу прочитать"), reading = L("Читаю"), done = L("Прочитано")
        return CatalogTemplate(
            id: "reading-list", category: .personal, title: L("Список чтения"),
            detail: L("Книги по статусу: хочу прочитать, читаю, прочитано"), icon: "📚",
            databases: [CatalogDatabase(
                key: "books", title: L("Список чтения"), titleProperty: name,
                properties: [.choice(status, .status, [o(want, "gray"), o(reading, "blue"), o(done, "green")]),
                             .plain(author, .text),
                             .choice(rating, .select, [o("★"), o("★★"), o("★★★", "yellow"), o("★★★★", "orange"), o("★★★★★", "red")]),
                             .choice(genre, .multiSelect, [o(L("Роман"), "purple"), o(L("Нон-фикшн"), "blue"), o(L("Фантастика"), "green"), o(L("Бизнес"), "brown")]),
                             .plain(finished, .date)],
                views: [CatalogView(name: L("По статусу"), kind: DatabaseView.boardKind, groupBy: status),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [name: .count]),
                        CatalogView(name: L("Галерея"), kind: DatabaseView.galleryKind)],
                records: [
                    CatalogRecord(key: "b1", title: L("Мастер и Маргарита"), values: [author: .text(L("Михаил Булгаков")), status: .option(done), rating: .option("★★★★★"), genre: .options([L("Роман")]), finished: .day(-20)]),
                    CatalogRecord(key: "b2", title: L("Думай медленно… решай быстро"), values: [author: .text(L("Даниэль Канеман")), status: .option(reading), genre: .options([L("Нон-фикшн")])]),
                    CatalogRecord(key: "b3", title: L("Солярис"), values: [author: .text(L("Станислав Лем")), status: .option(want), genre: .options([L("Фантастика")])]),
                ])])
    }

    static var goals: CatalogTemplate {
        let goal = L("Цель"), status = L("Статус"), area = L("Сфера"), period = L("Сроки"), progress = L("Прогресс, %")
        let notStarted = L("Не начато"), inProgress = L("В работе"), done = L("Достигнуто")
        return CatalogTemplate(
            id: "goals", category: .personal, title: L("Цели"),
            detail: L("Цели по сферам жизни со сроками и прогрессом"), icon: "⛰️",
            databases: [CatalogDatabase(
                key: "goals", title: L("Цели"), titleProperty: goal,
                properties: [.choice(status, .status, [o(notStarted, "red"), o(inProgress, "yellow"), o(done, "green")]),
                             .plain(period, .date),
                             .choice(area, .select, [o(L("Здоровье"), "green"), o(L("Карьера"), "blue"), o(L("Финансы"), "yellow"), o(L("Отношения"), "pink")]),
                             .plain(progress, .number)],
                views: [CatalogView(name: L("Доска"), kind: DatabaseView.boardKind, groupBy: status),
                        CatalogView(name: L("Хронология"), kind: DatabaseView.timelineKind, dateProperty: period, showTimelineTable: true),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [progress: .average])],
                records: [
                    CatalogRecord(key: "g1", title: L("Пробежать полумарафон"), values: [status: .option(inProgress), area: .option(L("Здоровье")), period: .day(-30, end: 90), progress: .number(40)]),
                    CatalogRecord(key: "g2", title: L("Подушка безопасности на 6 месяцев"), values: [status: .option(notStarted), area: .option(L("Финансы")), period: .day(10, end: 200), progress: .number(0)]),
                    CatalogRecord(key: "g3", title: L("Выучить английский до B2"), values: [status: .option(inProgress), area: .option(L("Карьера")), period: .day(-60, end: 120), progress: .number(55)]),
                ])])
    }

    static var travel: CatalogTemplate {
        let item = L("Пункт"), date = L("Когда"), type = L("Тип"), cost = L("Стоимость"), booked = L("Забронировано"), link = L("Ссылка")
        return CatalogTemplate(
            id: "travel", category: .personal, title: L("Планировщик поездки"),
            detail: L("Перелёты, жильё и места по дням; итог расходов внизу таблицы"), icon: "✈️",
            databases: [CatalogDatabase(
                key: "trip", title: L("Поездка"), titleProperty: item,
                properties: [.plain(date, .date),
                             .choice(type, .select, [o(L("Перелёт"), "blue"), o(L("Жильё"), "purple"), o(L("Место"), "green"), o(L("Еда"), "orange")]),
                             .plain(cost, .number), .plain(booked, .checkbox), .plain(link, .url)],
                views: [CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [cost: .sum, booked: .percentChecked], sorts: [(date, false)]),
                        CatalogView(name: L("Календарь"), kind: DatabaseView.calendarKind, dateProperty: date),
                        CatalogView(name: L("По типу"), kind: DatabaseView.boardKind, groupBy: type)],
                records: [
                    CatalogRecord(key: "t1", title: L("Перелёт туда"), values: [date: .day(14), type: .option(L("Перелёт")), cost: .number(12000), booked: .checkbox(true)]),
                    CatalogRecord(key: "t2", title: L("Отель в центре"), values: [date: .day(14, end: 18), type: .option(L("Жильё")), cost: .number(24000), booked: .checkbox(true)]),
                    CatalogRecord(key: "t3", title: L("Музей"), values: [date: .day(15), type: .option(L("Место")), cost: .number(1500)]),
                    CatalogRecord(key: "t4", title: L("Перелёт обратно"), values: [date: .day(18), type: .option(L("Перелёт")), cost: .number(11000)]),
                ])])
    }

    // MARK: Проекты

    static var roadmap: CatalogTemplate {
        let task = L("Задача"), status = L("Статус"), dates = L("Сроки"), priority = L("Приоритет"), kind = L("Тип"), sprint = L("Спринт")
        let notStarted = L("Не начато"), inProgress = L("В работе"), done = L("Готово")
        let feature = L("Задача 🔨"), bug = L("Ошибка 🐞")
        return CatalogTemplate(
            id: "roadmap", category: .projects, title: L("Дорожная карта"),
            detail: L("Доска по статусу, хронология с таблицей и приоритеты P1–P4"), icon: "🚘",
            databases: [CatalogDatabase(
                key: "roadmap", title: L("Дорожная карта"), titleProperty: task,
                properties: [.choice(status, .status, [o(notStarted, "red"), o(inProgress, "yellow"), o(done, "green")]),
                             .plain(dates, .date),
                             .choice(priority, .select, [o("P1 🔥", "red"), o("P2", "orange"), o("P3", "yellow"), o("P4", "green")]),
                             .choice(kind, .select, [o(feature, "yellow"), o(bug, "red")]),
                             .choice(sprint, .multiSelect, [o(L("Спринт 1"), "gray"), o(L("Спринт 2"), "gray"), o(L("Спринт 3"), "gray")])],
                views: [CatalogView(name: L("По статусу"), kind: DatabaseView.boardKind, groupBy: status, hidden: [dates]),
                        CatalogView(name: L("Хронология"), kind: DatabaseView.timelineKind, dateProperty: dates, hidden: [status, kind, sprint], showTimelineTable: true),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [task: .count, status: .countValues])],
                records: [
                    CatalogRecord(key: "r1", title: L("Переписать кэш запросов"), values: [status: .option(notStarted), dates: .day(2, end: 9), priority: .option("P1 🔥"), kind: .option(feature), sprint: .options([L("Спринт 2"), L("Спринт 3")])]),
                    CatalogRecord(key: "r2", title: L("Вход через Apple"), values: [status: .option(notStarted), dates: .day(5, end: 12), priority: .option("P2"), kind: .option(feature), sprint: .options([L("Спринт 2")])]),
                    CatalogRecord(key: "r3", title: L("Не показываются новые эмодзи"), values: [status: .option(inProgress), dates: .day(-2, end: 3), priority: .option("P2"), kind: .option(bug), sprint: .options([L("Спринт 1")])]),
                    CatalogRecord(key: "r4", title: L("Импорт из Evernote"), values: [status: .option(inProgress), dates: .day(-4, end: 6), priority: .option("P3"), kind: .option(feature), sprint: .options([L("Спринт 1"), L("Спринт 2")])]),
                    CatalogRecord(key: "r5", title: L("Импорт CSV больше 20 МБ"), values: [status: .option(done), dates: .day(-12, end: -5), priority: .option("P1 🔥"), kind: .option(bug), sprint: .options([L("Спринт 1")])]),
                    CatalogRecord(key: "r6", title: L("Ленивая загрузка"), values: [status: .option(done), dates: .day(-9, end: -3), priority: .option("P4"), kind: .option(feature), sprint: .options([L("Спринт 1")])]),
                ])])
    }

    static var projectSchedule: CatalogTemplate {
        let stage = L("Этап"), dates = L("Даты"), days = L("Длительность, дн."), kind = L("Тип"), done = L("Готово")
        let meeting = L("Встреча"), work = L("Работа"), payment = L("Оплата")
        return CatalogTemplate(
            id: "project-schedule", category: .projects, title: L("Расписание проекта"),
            detail: L("Этапы на хронологии с таблицей слева и расчётом длительности"), icon: "🗓️",
            databases: [CatalogDatabase(
                key: "schedule", title: L("Расписание проекта"), titleProperty: stage,
                properties: [.plain(dates, .date),
                             .choice(kind, .select, [o(meeting, "blue"), o(work, "brown"), o(payment, "green")]),
                             .plain(done, .checkbox),
                             .formula(days, "if(empty(prop(\"\(dates)\")), 0, dateBetween(dateEnd(prop(\"\(dates)\")), dateStart(prop(\"\(dates)\")), \"days\"))")],
                views: [CatalogView(name: L("Хронология"), kind: DatabaseView.timelineKind, dateProperty: dates, hidden: [kind, done], showTimelineTable: true),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [stage: .count, days: .sum, done: .percentChecked], sorts: [(dates, false)])],
                records: [
                    CatalogRecord(key: "s1", title: L("Подписание договора"), icon: "✒️", values: [dates: .day(0), kind: .option(meeting), done: .checkbox(true)]),
                    CatalogRecord(key: "s2", title: L("Предоплата (1/3)"), icon: "🧾", values: [dates: .day(0), kind: .option(payment), done: .checkbox(true)]),
                    CatalogRecord(key: "s3", title: L("Аудит процессов"), icon: "📦", values: [dates: .day(1, end: 15), kind: .option(work)]),
                    CatalogRecord(key: "s4", title: L("Встреча с командой"), icon: "💬", values: [dates: .day(1), kind: .option(meeting)]),
                    CatalogRecord(key: "s5", title: L("Командный спринт"), icon: "💬", values: [dates: .day(4, end: 5), kind: .option(meeting)]),
                    CatalogRecord(key: "s6", title: L("Промежуточная оплата (2/3)"), icon: "🧾", values: [dates: .day(10), kind: .option(payment)]),
                    CatalogRecord(key: "s7", title: L("Оптимизация процессов"), icon: "📦", values: [dates: .day(16, end: 44), kind: .option(work)]),
                ])])
    }

    static var tasks: CatalogTemplate {
        let task = L("Задача"), status = L("Статус"), due = L("Срок"), priority = L("Приоритет"), tags = L("Теги")
        let todo = L("К выполнению"), doing = L("В работе"), done = L("Готово")
        return CatalogTemplate(
            id: "tasks", category: .work, title: L("Список задач"),
            detail: L("Задачи на доске, в таблице и в календаре"), icon: "✅",
            databases: [CatalogDatabase(
                key: "tasks", title: L("Задачи"), titleProperty: task,
                properties: [.choice(status, .status, [o(todo, "gray"), o(doing, "blue"), o(done, "green")]),
                             .plain(due, .date),
                             .choice(priority, .select, [o(L("Высокий"), "red"), o(L("Средний"), "yellow"), o(L("Низкий"), "gray")]),
                             .choice(tags, .multiSelect, [o(L("Дом"), "green"), o(L("Работа"), "blue"), o(L("Покупки"), "orange")])],
                views: [CatalogView(name: L("Доска"), kind: DatabaseView.boardKind, groupBy: status),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [task: .count], sorts: [(due, false)]),
                        CatalogView(name: L("Календарь"), kind: DatabaseView.calendarKind, dateProperty: due)],
                records: [
                    CatalogRecord(key: "k1", title: L("Подготовить отчёт"), values: [status: .option(doing), due: .day(1), priority: .option(L("Высокий")), tags: .options([L("Работа")])]),
                    CatalogRecord(key: "k2", title: L("Купить продукты"), values: [status: .option(todo), due: .day(0), priority: .option(L("Средний")), tags: .options([L("Покупки"), L("Дом")])]),
                    CatalogRecord(key: "k3", title: L("Записаться к врачу"), values: [status: .option(done), due: .day(-2), priority: .option(L("Низкий")), tags: .options([L("Дом")])]),
                ])])
    }

    // MARK: Работа

    static var crm: CatalogTemplate {
        let company = L("Компания"), phone = L("Телефон"), stage = L("Этап"), ordersOfClient = L("Заказы"), clientTotal = L("Сумма заказов")
        let product = L("Товар"), price = L("Цена"), ordersOfProduct = L("Заказы с товаром")
        let number = L("Номер"), status = L("Статус заказа"), delivery = L("Доставка"), amount = L("Сумма"), client = L("Клиент"), goods = L("Товары")
        let accepted = L("Принят"), working = L("В работе"), completed = L("Выполнен"), cancelled = L("Отменён")
        return CatalogTemplate(
            id: "crm", category: .work, title: L("CRM"),
            detail: L("Клиенты, товары и заказы со связями, суммами и календарём доставок"), icon: "🤝", rootTitle: L("CRM"),
            databases: [
                CatalogDatabase(
                    key: "clients", title: L("Клиенты"), icon: "👤", titleProperty: company,
                    properties: [.plain(phone, .text),
                                 .choice(stage, .select, [o(L("Лид"), "gray"), o(L("Переговоры"), "yellow"), o(L("Клиент"), "green")]),
                                 .rollup(clientTotal, relation: ordersOfClient, property: amount, .sum)],
                    views: [CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [company: .count, clientTotal: .sum]),
                            CatalogView(name: L("Воронка"), kind: DatabaseView.boardKind, groupBy: stage)],
                    records: [CatalogRecord(key: "c1", title: L("ООО «Север»"), values: [phone: .text("+7 900 000-00-01"), stage: .option(L("Клиент"))]),
                              CatalogRecord(key: "c2", title: L("ИП Иванов"), values: [phone: .text("+7 900 000-00-02"), stage: .option(L("Переговоры"))])]),
                CatalogDatabase(
                    key: "products", title: L("Товары"), icon: "📦", titleProperty: product,
                    properties: [.plain(price, .number)],
                    views: [CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [product: .count, price: .average])],
                    records: [CatalogRecord(key: "p1", title: L("Консультация"), values: [price: .number(3000)]),
                              CatalogRecord(key: "p2", title: L("Настройка"), values: [price: .number(6600)])]),
                CatalogDatabase(
                    key: "orders", title: L("Заказы"), icon: "🧾", titleProperty: number,
                    properties: [.choice(status, .status, [o(accepted, "orange"), o(working, "blue"), o(completed, "green"), o(cancelled, "red")]),
                                 .plain(delivery, .date), .plain(amount, .number)],
                    views: [CatalogView(name: L("Все заказы"), kind: DatabaseView.boardKind, groupBy: status),
                            CatalogView(name: L("Календарь доставок"), kind: DatabaseView.calendarKind, dateProperty: delivery),
                            CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [number: .count, amount: .sum])],
                    records: [CatalogRecord(key: "o1", title: "1000", values: [status: .option(completed), delivery: .day(-3), amount: .number(13200), client: .relation(["c1"]), goods: .relation(["p2"])]),
                              CatalogRecord(key: "o2", title: "1001", values: [status: .option(working), delivery: .day(4), amount: .number(6600), client: .relation(["c2"]), goods: .relation(["p1"])])]),
            ],
            relations: [CatalogRelation(from: "orders", name: client, to: "clients", pairName: ordersOfClient),
                        CatalogRelation(from: "orders", name: goods, to: "products", pairName: ordersOfProduct)])
    }

    static var jobApplications: CatalogTemplate {
        let company = L("Компания"), position = L("Должность"), status = L("Статус"), applied = L("Дата отклика"), salary = L("Зарплата"), link = L("Вакансия")
        let sent = L("Отклик отправлен"), interview = L("Собеседование"), offer = L("Оффер"), rejected = L("Отказ")
        return CatalogTemplate(
            id: "job-applications", category: .work, title: L("Поиск работы"),
            detail: L("Отклики по этапам: от отправки до оффера"), icon: "💼",
            databases: [CatalogDatabase(
                key: "jobs", title: L("Поиск работы"), titleProperty: company,
                properties: [.plain(position, .text),
                             .choice(status, .status, [o(sent, "gray"), o(interview, "blue"), o(offer, "green"), o(rejected, "red")]),
                             .plain(applied, .date), .plain(salary, .number), .plain(link, .url)],
                views: [CatalogView(name: L("Доска"), kind: DatabaseView.boardKind, groupBy: status),
                        CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [company: .count, salary: .average], sorts: [(applied, true)])],
                records: [CatalogRecord(key: "j1", title: L("Компания А"), values: [position: .text(L("Дизайнер")), status: .option(interview), applied: .day(-6), salary: .number(180000)]),
                          CatalogRecord(key: "j2", title: L("Компания Б"), values: [position: .text(L("Продакт-менеджер")), status: .option(sent), applied: .day(-2), salary: .number(220000)])])])
    }

    // MARK: Учёба

    static var coursePlanner: CatalogTemplate {
        let assignment = L("Задание"), course = L("Предмет"), kind = L("Тип"), due = L("Срок"), done = L("Сдано"), grade = L("Оценка")
        return CatalogTemplate(
            id: "course-planner", category: .study, title: L("Учебный планировщик"),
            detail: L("Задания и экзамены по предметам, сроки в календаре"), icon: "🎓",
            databases: [CatalogDatabase(
                key: "study", title: L("Учёба"), titleProperty: assignment,
                properties: [.choice(course, .select, [o(L("Математика"), "blue"), o(L("История"), "brown"), o(L("Английский"), "green")]),
                             .choice(kind, .select, [o(L("Домашнее задание"), "gray"), o(L("Лабораторная"), "purple"), o(L("Экзамен"), "red")]),
                             .plain(due, .date), .plain(done, .checkbox), .plain(grade, .number)],
                views: [CatalogView(name: L("Таблица"), kind: DatabaseView.tableKind, calculations: [done: .percentChecked, grade: .average], sorts: [(due, false)]),
                        CatalogView(name: L("Календарь"), kind: DatabaseView.calendarKind, dateProperty: due),
                        CatalogView(name: L("По предметам"), kind: DatabaseView.boardKind, groupBy: course)],
                records: [CatalogRecord(key: "a1", title: L("Задачи 1–10"), values: [course: .option(L("Математика")), kind: .option(L("Домашнее задание")), due: .day(2)]),
                          CatalogRecord(key: "a2", title: L("Эссе о реформах"), values: [course: .option(L("История")), kind: .option(L("Домашнее задание")), due: .day(-1), done: .checkbox(true), grade: .number(5)]),
                          CatalogRecord(key: "a3", title: L("Итоговый экзамен"), values: [course: .option(L("Английский")), kind: .option(L("Экзамен")), due: .day(21)])])])
    }
}
