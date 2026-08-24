package com.voiid.app.main.games.ludo

/**
 * Accessibility labels (§17). VoiceOver/TalkBack order is close → help → top pods → die →
 * legal pawns → board summary → bottom pods → chat; the screen composes in exactly that
 * order. Color is NEVER the only carrier: the border hue alone cannot be spoken, so the
 * board container states the active seat and a pawn summary.
 */
object LudoSemantics {

    fun boardSummary(state: LudoGameState): String {
        val players = state.seats.size
        val activeColor = state.turn?.seat?.let { colorName(it) } ?: "no active"
        val viewer = state.viewerSeat
        val myPawns = if (viewer != null && state.tokens.getOrNull(viewer) != null) {
            state.tokens[viewer].count { it == LudoRules.FINISHED }
        } else 0
        return "Ludo board, $players players, $activeColor action, you have $myPawns of 4 pawns home"
    }

    /** "Safe track cell 8, row 9 column 3, occupied by one red pawn" (§17). */
    fun cellLabel(node: LudoBoardGeometry.CellNode, state: LudoGameState): String {
        val rowCol = ", row ${node.y + 1} column ${node.x + 1}"
        return when (node.role) {
            LudoBoardGeometry.Role.SHARED_TRACK -> buildString {
                append(if (node.isSafe) "Safe track cell ${node.trackIndex}" else "Track cell ${node.trackIndex}")
                append(rowCol)
                occupants(state, node)?.let { append(", $it") }
            }
            LudoBoardGeometry.Role.HOME_LANE ->
                "${colorName(node.seat ?: 0)} home lane, step ${(node.homeStep ?: 0) + 1} of 5$rowCol"
            LudoBoardGeometry.Role.YARD_POCKET -> {
                // Slot numbering follows pawn index within the seat's yard.
                val slots = LudoBoardGeometry.YARD_SLOTS[node.seat ?: 0]
                val pawn = slots.indexOf(node.x to node.y)
                if (pawn >= 0) "Yard slot ${pawn + 1}$rowCol" else "Yard$rowCol"
            }
            LudoBoardGeometry.Role.YARD ->
                (node.seat?.let { "${colorName(it)} yard" } ?: "Yard") + rowCol
            LudoBoardGeometry.Role.CENTER -> "Center finish$rowCol"
            LudoBoardGeometry.Role.UNUSED -> ""
        }
    }

    private fun occupants(state: LudoGameState, node: LudoBoardGeometry.CellNode): String? {
        node.trackIndex ?: return null
        var count = 0
        var color = ""
        for ((seat, row) in state.tokens.withIndex()) {
            if (row.contains(node.trackIndex)) {
                count++
                color = colorName(seat)
            }
        }
        return when (count) {
            0 -> null
            1 -> "occupied by one $color pawn"
            else -> "occupied by $count pawns"
        }
    }

    /** Pawn label per §17; legal pawns add the button trait upstream plus this hint. */
    fun pawnLabel(state: LudoGameState, seat: Int, pawn: Int, displayName: String): String {
        val pos = state.tokens.getOrNull(seat)?.getOrNull(pawn) ?: LudoRules.YARD
        val where = when {
            pos == LudoRules.YARD -> "yard"
            pos == LudoRules.FINISHED -> "finished"
            pos >= LudoRules.HOME_LANE_BASE -> "home lane step ${pos - LudoRules.HOME_LANE_BASE + 1}"
            else -> "track cell $pos"
        }
        return "$displayName, ${colorName(seat)} pawn ${pawn + 1}, $where"
    }

    fun legalHint(state: LudoGameState, token: Int): String? {
        val turn = state.turn ?: return null
        val value = turn.value ?: return null
        val pos = state.tokens.getOrNull(turn.seat)?.getOrNull(token) ?: return null
        val dest = destDescription(pos, value, turn.seat)
        return "Moves $value spaces to $dest"
    }

    private fun destDescription(from: Int, die: Int, seat: Int): String {
        val dest = when {
            from == LudoRules.YARD -> if (die == 6) LudoRules.startIndex(seat) else null
            from >= LudoRules.HOME_LANE_BASE -> {
                val sum = (from - LudoRules.HOME_LANE_BASE) + die
                when {
                    sum == LudoRules.HOME_LANE_COUNT -> LudoRules.FINISHED
                    sum > LudoRules.HOME_LANE_COUNT -> null
                    else -> LudoRules.HOME_LANE_BASE + sum
                }
            }
            else -> {
                val travelled = LudoRules.progressOf(from, seat)
                val total = travelled + die
                when {
                    total == LudoRules.TRACK_COUNT + LudoRules.HOME_LANE_COUNT -> LudoRules.FINISHED
                    total > LudoRules.TRACK_COUNT + LudoRules.HOME_LANE_COUNT -> null
                    total >= LudoRules.TRACK_COUNT -> LudoRules.HOME_LANE_BASE + (total - LudoRules.TRACK_COUNT)
                    else -> (LudoRules.startIndex(seat) + total) % LudoRules.TRACK_COUNT
                }
            }
        } ?: return "an illegal square"
        return when {
            dest == LudoRules.FINISHED -> "home"
            dest >= LudoRules.HOME_LANE_BASE -> "home lane step ${dest - LudoRules.HOME_LANE_BASE + 1}"
            else -> "track cell $dest"
        }
    }

    /** Die at rest vs during animation announce ONLY settled results (§17). */
    fun dieLabel(state: LudoGameState, displayedValue: Int): String {
        val turn = state.turn
        val name = state.seats.firstOrNull { it.seat == turn?.seat }?.displayName ?: ""
        return when {
            state.isFinished || turn == null -> "Die"
            turn.value == null && turn.phase == "awaitingRoll" && state.viewerSeat == turn.seat ->
                "Die, double tap to roll"
            else -> "Die, $name showing $displayedValue"
        }
    }

    fun rollAnnouncement(state: LudoGameState, name: String, value: Int): String =
        "$name rolled $value"

    fun colorName(seat: Int): String = when (seat % 4) {
        0 -> "red"; 1 -> "green"; 2 -> "yellow"; else -> "blue"
    }
}
