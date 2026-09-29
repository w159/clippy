import Foundation

/// SYNTHETIC labelled fixture for suggestion-ranker calibration (ROADMAP INT-03).
/// Every string is invented for this test; none is real user, client, or firm data.
/// 5 topics x 3 subtopics; each subtopic has 2 clips and 2 contexts. A context's
/// relevant set is the 2 clips of its own subtopic, giving 60 labelled
/// context/clip pairs against a pool of 30 clips.
enum SuggestionCalibrationFixture {
    struct Subtopic {
        var topic: String
        var name: String
        var clips: [String]
        var contexts: [String]
    }

    static let subtopics: [Subtopic] = [
        // MARK: travel
        Subtopic(
            topic: "travel", name: "lisbon-trip",
            clips: [
                "Flight TP205 to Lisbon departs at 9:40 and lands at 12:15, hotel check-in after 3 pm near the old town",
                "Lisbon itinerary: Alfama walking tour, tram 28, pastel de nata bakery, day trip to Sintra castle",
            ],
            contexts: [
                "Planning our trip to Lisbon next month, still need to book flights and a hotel in the old town",
                "Draft email: here is the itinerary for Portugal, we land in Lisbon and visit Sintra and Alfama",
            ]),
        Subtopic(
            topic: "travel", name: "hiking-packing",
            clips: [
                "Packing list: waterproof jacket, trekking poles, water filter, headlamp, first aid kit, wool socks",
                "Trail notes: 14 km loop, 900 metres of climbing, bring extra water, start before sunrise to avoid heat",
            ],
            contexts: [
                "What should I bring for a three day hiking trip in the mountains, checking my gear and packing list",
                "Weekend trek this Saturday, long climb on the trail so we need water, boots and a headlamp",
            ]),
        Subtopic(
            topic: "travel", name: "visa-transfer",
            clips: [
                "Passport must be valid for six months after arrival; the tourist visa application takes five business days",
                "Airport transfer: shuttle pickup at terminal 2 arrivals, driver holds a sign, fare 35 euros to the city centre",
            ],
            contexts: [
                "Do I need a visa and a valid passport to enter the country as a tourist next spring",
                "Arranging the airport pickup and the shuttle ride from the terminal to the city centre",
            ]),
        // MARK: finance-generic
        Subtopic(
            topic: "finance", name: "budget",
            clips: [
                "Monthly budget: rent 1400, groceries 450, utilities 180, transport 90, savings target 500 per month",
                "Expense tracker categories: dining out, subscriptions, insurance, fuel, entertainment, monthly totals",
            ],
            contexts: [
                "Updating my household budget spreadsheet with this month's rent, groceries and utilities spending",
                "Reviewing where the money goes each month, tracking expenses by category and savings goal",
            ]),
        Subtopic(
            topic: "finance", name: "invoice-terms",
            clips: [
                "Invoice 2041 total 3200 dollars, payment terms net 30, a late fee of 1.5 percent applies after the due date",
                "Please remit payment by bank transfer to the account on the invoice, quote the invoice number as reference",
            ],
            contexts: [
                "Writing a reminder that the invoice is overdue and payment terms are net 30 with a late fee",
                "Customer asks how to pay the outstanding invoice and which reference number to use for the transfer",
            ]),
        Subtopic(
            topic: "finance", name: "index-funds",
            clips: [
                "A broad market index fund holds hundreds of stocks with a low expense ratio and diversifies risk",
                "Retirement account contribution limits change yearly; regular monthly contributions benefit from compounding",
            ],
            contexts: [
                "Explaining to a friend why a low cost diversified index fund suits long term investing",
                "How much can I contribute to my retirement account this year and does compounding really matter",
            ]),
        // MARK: code
        Subtopic(
            topic: "code", name: "swift-concurrency",
            clips: [
                "func load() async throws -> [Item] { try await withThrowingTaskGroup(of: Item.self) { group in group.addTask { try await fetch() } } }",
                "Use @MainActor for UI state, mark shared mutable state as actor isolated, and avoid data races with Sendable types",
            ],
            contexts: [
                "func refresh() async { let items = await try? loadItems() } need a task group with async await here",
                "Compiler warns about data races, the view model should be a MainActor isolated type with Sendable values",
            ]),
        Subtopic(
            topic: "code", name: "sql-performance",
            clips: [
                "SELECT customer_id, COUNT(*) FROM orders WHERE created_at > now() - interval '7 days' GROUP BY customer_id",
                "CREATE INDEX idx_orders_created ON orders (created_at); check the query plan with EXPLAIN ANALYZE for a sequential scan",
            ],
            contexts: [
                "This SQL query on the orders table is slow, it does a sequential scan and needs an index",
                "SELECT rows grouped by customer with a where clause on created date, optimise the query plan",
            ]),
        Subtopic(
            topic: "code", name: "git-conflicts",
            clips: [
                "git rebase -i HEAD~4 then squash the fixup commits and force push with lease to the feature branch",
                "Resolve the merge conflict markers, run git add on the file, then git rebase --continue",
            ],
            contexts: [
                "Git says there is a merge conflict during my rebase, how do I continue after fixing the markers",
                "Clean up the feature branch history by squashing commits before opening the pull request",
            ]),
        // MARK: meetings
        Subtopic(
            topic: "meetings", name: "standup",
            clips: [
                "Standup agenda: yesterday's progress, today's plan, blockers, and anything needing help from the team",
                "Blocker: the staging deploy is failing on the migration step, waiting on the platform team for access",
            ],
            contexts: [
                "Daily standup in five minutes, I need to share progress, plans for today and my blockers",
                "Notes for the team sync: deploy to staging is blocked, we need help from the platform team",
            ]),
        Subtopic(
            topic: "meetings", name: "planning-offsite",
            clips: [
                "Quarterly planning offsite agenda: review objectives, prioritise the roadmap, assign owners, set milestones",
                "Offsite logistics: conference room booked Tuesday 9 to 4, lunch catered, projector and whiteboards needed",
            ],
            contexts: [
                "Preparing the agenda for next quarter's planning session, objectives, roadmap priorities and owners",
                "Booking the room and catering for the all day team offsite on Tuesday",
            ]),
        Subtopic(
            topic: "meetings", name: "one-on-one",
            clips: [
                "One on one notes: career goals, feedback on the last project, growth areas, and mentoring opportunities",
                "Action items: send the reading list, schedule the follow up in two weeks, share feedback with the manager",
            ],
            contexts: [
                "Getting ready for my one on one with my manager to talk about feedback and career growth",
                "Wrapping up the meeting, listing action items and scheduling a follow up in two weeks",
            ]),
        // MARK: shopping
        Subtopic(
            topic: "shopping", name: "laptop",
            clips: [
                "Laptop comparison: 14 inch, 16 GB memory, battery lasts 18 hours, lightweight aluminium body, 1200 dollars",
                "Review: great display and keyboard, fast processor, fans stay quiet, battery easily lasts a full workday",
            ],
            contexts: [
                "Deciding which new laptop to buy, comparing battery life, memory, screen and price",
                "Looking for reviews of a lightweight laptop with a great keyboard, display and long battery",
            ]),
        Subtopic(
            topic: "shopping", name: "groceries-pasta",
            clips: [
                "Grocery list: spaghetti, canned tomatoes, garlic, basil, parmesan, olive oil, red onions, mushrooms",
                "Pasta recipe: boil the spaghetti eight minutes, simmer tomatoes with garlic and basil, finish with parmesan",
            ],
            contexts: [
                "Going to the supermarket tonight, need ingredients to cook spaghetti with tomato sauce",
                "What do I need to buy to make a simple pasta dinner with garlic, basil and cheese",
            ]),
        Subtopic(
            topic: "shopping", name: "running-shoes",
            clips: [
                "Running shoes size 10 on sale, 30 percent discount code SPRING30, free returns within 60 days",
                "Shoe guide: cushioned trainers for road running, check the fit, half a size up for long distances",
            ],
            contexts: [
                "Buying a new pair of running shoes, is there a discount code and what size should I choose",
                "Which cushioned trainers are best for road running and long distances",
            ]),
    ]

    /// Flat clip pool: index = position in this array, so `subtopicIndex * 2 + n`.
    static var pool: [(text: String, subtopic: Int)] {
        subtopics.enumerated().flatMap { index, sub in sub.clips.map { ($0, index) } }
    }

    /// Every context with the pool indices judged relevant.
    static var cases: [(context: String, relevant: Set<Int>, topic: String)] {
        subtopics.enumerated().flatMap { index, sub in
            sub.contexts.map { ($0, Set([index * 2, index * 2 + 1]), sub.topic) }
        }
    }
}
