ConsistencyError = (message) ->
	error = new Error(message)
	error.name = "ConsistencyError"
	error.__proto__ = ConsistencyError.prototype
	return error
ConsistencyError.prototype.__proto__ = Error.prototype

module.exports = DiffGenerator =
	ConsistencyError: ConsistencyError

	rewindUpdate: (content, update) ->
		for op in update.op.slice().reverse()
			content = DiffGenerator.rewindOp content, op
		return content

	rewindOp: (content, op) ->
		if op.i?
			textToBeRemoved = content.slice(op.p, op.p + op.i.length)
			if op.i != textToBeRemoved
				throw new ConsistencyError(
					"Inserted content, '#{op.i}', does not match text to be removed, '#{textToBeRemoved}'"
				)

			return content.slice(0, op.p) + content.slice(op.p + op.i.length)

		else if op.d?
			return content.slice(0, op.p) + op.d + content.slice(op.p)

	rewindUpdates: (content, updates) ->
		for update in updates.reverse()
			content = DiffGenerator.rewindUpdate(content, update)
		return content

	buildDiff: (initialContent, updates) ->
		diff = [ u: initialContent ]
		for update in updates
			diff = DiffGenerator.applyUpdateToDiff diff, update
		diff = DiffGenerator.compressDiff diff
		return diff

	compressDiff: (diff) ->
		newDiff = []
		for part in diff
			lastPart = newDiff[newDiff.length - 1]
			if lastPart? and lastPart.meta?.user? and part.meta?.user?
				if lastPart.i? and part.i? and lastPart.meta.user.id == part.meta.user.id
					lastPart.i += part.i
					lastPart.meta.start_ts = Math.min(lastPart.meta.start_ts, part.meta.start_ts)
					lastPart.meta.end_ts = Math.max(lastPart.meta.end_ts, part.meta.end_ts)
				else if lastPart.d? and part.d? and lastPart.meta.user.id == part.meta.user.id
					lastPart.d += part.d
					lastPart.meta.start_ts = Math.min(lastPart.meta.start_ts, part.meta.start_ts)
					lastPart.meta.end_ts = Math.max(lastPart.meta.end_ts, part.meta.end_ts)
				else
					newDiff.push part
			else
				newDiff.push part
		return newDiff

	applyOpToDiff: (diff, op, meta) ->
		position = 0

		remainingDiff = diff.slice()
		{consumedDiff, remainingDiff} = DiffGenerator._consumeToOffset(remainingDiff, op.p)
		newDiff = consumedDiff

		if op.i?
			newDiff.push
				i: op.i
				meta: meta
		else if op.d?
			{consumedDiff, remainingDiff} = DiffGenerator._consumeDiffAffectedByDeleteOp remainingDiff, op, meta
			newDiff.push(consumedDiff...)

		newDiff.push(remainingDiff...)

		return newDiff

	applyUpdateToDiff: (diff, update) ->
		for op in update.op
			diff = DiffGenerator.applyOpToDiff diff, op, update.meta
		return diff

	_consumeToOffset: (remainingDiff, totalOffset) ->
		consumedDiff = []
		position = 0
		while part = remainingDiff.shift()
			length = DiffGenerator._getLengthOfDiffPart part
			if part.d?
				consumedDiff.push part
			else if position + length >= totalOffset
				partOffset = totalOffset - position
				if partOffset > 0
					consumedDiff.push DiffGenerator._slicePart part, 0, partOffset
				if partOffset < length
					remainingDiff.unshift DiffGenerator._slicePart part, partOffset
				break
			else
				position += length
				consumedDiff.push part

		return {
			consumedDiff: consumedDiff
			remainingDiff: remainingDiff
		}

	_consumeDiffAffectedByDeleteOp: (remainingDiff, deleteOp, meta) ->
		consumedDiff = []
		remainingOp = deleteOp
		while remainingOp and remainingDiff.length > 0
			{newPart, remainingDiff, remainingOp} = DiffGenerator._consumeDeletedPart remainingDiff, remainingOp, meta
			consumedDiff.push newPart if newPart?
		return {
			consumedDiff: consumedDiff
			remainingDiff: remainingDiff
		}

	_consumeDeletedPart: (remainingDiff, op, meta) ->
		part = remainingDiff.shift()
		partLength = DiffGenerator._getLengthOfDiffPart part

		if part.d?
			# Skip existing deletes
			remainingOp = op
			newPart = part

		else if partLength > op.d.length
			# Only the first bit of the part has been deleted
			remainingPart = DiffGenerator._slicePart part, op.d.length
			remainingDiff.unshift remainingPart

			deletedContent = DiffGenerator._getContentOfPart(part).slice(0, op.d.length)
			if deletedContent != op.d
				throw new ConsistencyError("deleted content, '#{deletedContent}', does not match delete op, '#{op.d}'")

			if part.u?
				newPart =
					d: op.d
					meta: meta
			else if part.i?
				newPart = null

			remainingOp = null

		else if partLength == op.d.length
			# The entire part has been deleted, but it is the last part

			deletedContent = DiffGenerator._getContentOfPart(part)
			if deletedContent != op.d
				throw new ConsistencyError("deleted content, '#{deletedContent}', does not match delete op, '#{op.d}'")

			if part.u?
				newPart =
					d: op.d
					meta: meta
			else if part.i?
				newPart = null

			remainingOp = null

		else if partLength < op.d.length
			# The entire part has been deleted and there is more

			deletedContent = DiffGenerator._getContentOfPart(part)
			opContent = op.d.slice(0, deletedContent.length)
			if deletedContent != opContent
				throw new ConsistencyError("deleted content, '#{deletedContent}', does not match delete op, '#{opContent}'")

			if part.u
				newPart =
					d: part.u
					meta: meta
			else if part.i?
				newPart = null

			remainingOp =
				p: op.p, d: op.d.slice(DiffGenerator._getLengthOfDiffPart(part))

		return {
			newPart: newPart
			remainingDiff: remainingDiff
			remainingOp: remainingOp
		}

	_slicePart: (basePart, from, to) ->
		if basePart.u?
			part = { u: basePart.u.slice(from, to) }
		else if basePart.i?
			part = { i: basePart.i.slice(from, to) }
		if basePart.meta?
			part.meta = basePart.meta
		return part

	_getLengthOfDiffPart: (part) ->
		(part.u or part.d or part.i or '').length

	_getContentOfPart: (part) ->
		part.u or part.d or part.i or ''
