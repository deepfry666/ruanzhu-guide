import Foundation

extension GatewayJob {
    func handleSuccess(_ attempt: Attempt, _ result: AttemptResult) async {
        clearTimers(attempt)
        releaseSlots(attempt)
        let check = gateway.checkImage(result.bytes)
        guard check.ok, let png = check.png else {
            await handleFailure(attempt, ProviderError(check.reason ?? "图片无效", kind: "invalid-image"))
            return
        }
        removeActive(attempt)
        background[attempt.attemptId] = nil
        let durationMs = gateway.now() - (attempt.startedAt ?? gateway.now())
        await gateway.health.recordSuccess(attempt.provider.id)
        if !settled {
            settled = true
            do {
                try gateway.installFile(request.outputPath, png, request.archiveRoot)
            } catch {
                finish(.failure(error))
                return
            }
            await logCall(attempt, .obj(["ok": true, "kind": "success", "outcome": "winner", "width": JSON.maybe(check.width), "height": JSON.maybe(check.height), "hedged": .bool(hedged)]))
            var attemptWin = ImageAttempt(.emptyObject)
            attemptWin.state = "completed"
            attemptWin.outcome = "winner"
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, attemptWin)
            var jobWin = ImageJob(.emptyObject)
            jobWin.state = "done"
            jobWin.winnerAttemptId = attempt.attemptId
            jobWin.providerId = attempt.provider.id
            await gateway.ledger.finishJob(jobId, jobWin)
            for id in activeOrder {
                guard let other = active[id] else { continue }
                if isAsyncProvider(other.provider), other.taskId != nil {
                    // 异步任务已经在中转站跑了，取消也不退钱：继续在后台查，出图后存为备选。
                    removeActive(other)
                    background[other.attemptId] = other
                    clearTimers(other)
                } else {
                    other.abortReason = "loser"
                    other.abort()
                }
            }
            emit(.obj(["type": "winner", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "durationMs": .number(durationMs), "hedged": .bool(hedged)]))
            finish(.success(GenerateResult(
                jobId: jobId, outputPath: request.outputPath, providerId: attempt.provider.id, providerName: attempt.provider.name, model: attempt.provider.model,
                requestSize: attempt.sizeSpec?.size, width: check.width, height: check.height, durationMs: gateway.now() - startedAt,
                hedged: hedged, attempts: started, warnings: check.warnings
            )))
        } else {
            do {
                let file = try gateway.saveAlternate(alternatesDir: request.alternatesDir, screenId: request.screenId, providerId: attempt.provider.id, png: png)
                await logCall(attempt, .obj(["ok": true, "kind": "success", "outcome": "alternate", "width": JSON.maybe(check.width), "height": JSON.maybe(check.height)]))
                var alt = ImageAttempt(.emptyObject)
                alt.state = "completed"
                alt.outcome = "alternate"
                alt.alternatePath = file
                await gateway.ledger.finishAttempt(jobId, attempt.attemptId, alt)
                emit(.obj(["type": "alternate", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "file": .string(file)]))
            } catch {}
        }
    }

    func handleFailure(_ attempt: Attempt, _ rawError: Error) async {
        clearTimers(attempt)
        releaseSlots(attempt)
        removeActive(attempt)
        let wasBackground = background.removeValue(forKey: attempt.attemptId) != nil
        var error: ProviderError
        if let providerError = rawError as? ProviderError {
            error = providerError
        } else if isCancellation(rawError) {
            error = ProviderError.aborted()
        } else {
            error = ProviderError(messageOf(rawError), kind: "unknown")
        }
        if error.kind == "aborted", attempt.abortReason == "timeout" {
            error = ProviderError("超过 \(JSON.formatNumber(attempt.provider.hardTimeoutSec == 0 ? 240 : attempt.provider.hardTimeoutSec)) 秒没有出图", kind: "timeout")
        }
        let message = redact(error.message, secretValues)
        if error.kind == "aborted" {
            let outcome = attempt.abortReason ?? "canceled"
            if attempt.startedAt != nil { await logCall(attempt, .obj(["ok": false, "kind": "aborted", "outcome": .string(outcome), "errorMessage": "已取消"])) }
            var aborted = ImageAttempt(.emptyObject)
            aborted.state = "aborted"
            aborted.outcome = outcome
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, aborted)
            if !settled, attempt.abortReason != "loser" { failover() }
            return
        }
        await logCall(attempt, .obj(["ok": false, "kind": .string(error.kind), "httpStatus": JSON.maybe(error.status), "errorMessage": .string(message)]))
        var failed = ImageAttempt(.emptyObject)
        failed.state = "failed"
        failed.error = message
        failed.kind = error.kind
        await gateway.ledger.finishAttempt(jobId, attempt.attemptId, failed)
        if !["content", "size", "pending"].contains(error.kind) {
            await gateway.health.recordFailure(attempt.provider.id, kind: error.kind, message: message, retryAfterSec: error.retryAfterSec)
        }
        emit(.obj(["type": "attempt-failed", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "kind": .string(error.kind), "message": .string(message)]))
        if settled || (wasBackground && !active.isEmpty) { return }

        if error.kind == "size", sizeOverrides[attempt.provider.id] == nil,
           let fallback = sizeFallback(error, attempt.provider, imageSettings.targetSize, attempt.sizeSpec?.size) {
            // 线路不支持当前尺寸：按报错改用它支持的尺寸立即重试，并记到线路配置里，以后直接用对的尺寸
            sizeOverrides[attempt.provider.id] = fallback.spec
            await gateway.updateProvider(attempt.provider.id, fallback)
            emit(.obj(["type": "size-switched", "providerId": .string(attempt.provider.id), "ratio": .string(fallback.spec.size)]))
            tried.removeAll { $0 == attempt.provider.id }
            started -= 1
            launch(attempt.provider, role: attempt.role)
            return
        }

        failures.append((attempt.provider.id, attempt.provider.name, error.kind, message))
        if error.kind == "server" || error.kind == "network", !retried.contains(attempt.provider.id), started < maxAttempts {
            retried.insert(attempt.provider.id)
            try? await gateway.sleepImpl(gateway.randomDelayMs())
            if settled { return }
            tried.removeAll { $0 == attempt.provider.id }
            launch(attempt.provider, role: "retry")
            return
        }
        failover()
    }

    func onHedgeTimer(_ attempt: Attempt) async {
        if settled || hedged || active[attempt.attemptId] == nil { return }
        guard let candidate = gateway.pickHedgeProvider(providers, attempt.provider, tried, hedge) else { return }
        if let batchId = request.batchId {
            guard gateway.takeHedgeSlot(batchId, limit: hedge.maxPerBatch) else { return }
        }
        hedged = true
        emit(.obj(["type": "hedge", "fromProviderId": .string(attempt.provider.id), "providerId": .string(candidate.id), "providerName": .string(candidate.name)]))
        launch(candidate, role: "hedge")
    }

    func onHardTimeout(_ attempt: Attempt) async {
        if settled || active[attempt.attemptId] == nil { return }
        if isAsyncProvider(attempt.provider), let taskId = attempt.taskId {
            // 异步任务超时：不放弃任务号，转后台继续查；同时换下一条线路。
            removeActive(attempt)
            background[attempt.attemptId] = attempt
            releaseSlots(attempt)
            emit(.obj(["type": "attempt-background", "providerId": .string(attempt.provider.id), "taskId": .string(taskId)]))
            failures.append((attempt.provider.id, attempt.provider.name, "timeout", "超时，已转后台继续查询"))
            if active.isEmpty, let next = nextProvider(), started < maxAttempts { launch(next, role: "failover") }
            return
        }
        attempt.abortReason = "timeout"
        attempt.abort()
    }
}
