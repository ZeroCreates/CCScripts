local function cleanText(value, minimum, maximum, multiline)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    local checked = multiline and value:gsub("\n", "") or value
    if #value < minimum or #value > maximum or checked:find("%c") then return nil end
    return value
end

local function findJob(state, jobId)
    for _, job in pairs(state.jobs) do
        if job.id == jobId then return job end
    end
end

local function belongsToUser(job, field, legacyId, senderId, username)
    local owner = job[field]
    if owner then return owner == username end
    return job[legacyId] == senderId
end

local function copyJob(job)
    local copy = {}
    for key, value in pairs(job) do copy[key] = value end
    return copy
end

local function createJobsServer(state, saveState)
    local function cleanupJobs()
        local now = os.epoch("utc")
        local retained = {}
        local changed = false
        for _, job in ipairs(state.jobs) do
            if job.status == "completed" or job.status == "cancelled" then
                local updatedAt = job.updatedAt
                if type(updatedAt) ~= "number" or updatedAt ~= updatedAt
                    or updatedAt < 0 or updatedAt == math.huge then
                    job = copyJob(job)
                    job.updatedAt = now
                    changed = true
                elseif now - updatedAt >= 3 * 60 * 60 * 1000 then
                    job = nil
                    changed = true
                end
            end
            if job then table.insert(retained, job) end
        end
        if not changed then return true end
        local previousJobs = state.jobs
        state.jobs = retained
        local ok, saved, saveError = pcall(saveState)
        if not ok or not saved then
            state.jobs = previousJobs
            return false, ok and saveError or tostring(saved)
        end
        return true
    end

    local function mutateJob(senderId, job, changes, responseType, clearFields)
        local previous = copyJob(job)
        for key, value in pairs(changes) do job[key] = value end
        for _, key in pairs(clearFields or {}) do job[key] = nil end
        job.updatedAt = os.epoch("utc")
        local saved, saveError = saveState()
        if not saved then
            for key in pairs(job) do job[key] = nil end
            for key, value in pairs(previous) do job[key] = value end
            return { type = "error", message = saveError }
        end
        return { type = responseType, job = copyJob(job) }
    end

    local function createJob(senderId, username, message)
        local title = cleanText(message.title, 3, 40)
        local description = cleanText(message.description, 5, 360, true)
        local reward = cleanText(message.reward, 1, 60)
        local kind = message.kind == nil and "request" or message.kind
        if kind ~= "request" and kind ~= "offer" then
            return { type = "error", message = "Choose a job request or service offer." }
        end
        if not title or not description or not reward then
            return { type = "error", message = "Enter a title (3-40 chars), details (5-180), and reward (1-60)." }
        end

        local job = {
            id = state.nextId,
            posterId = senderId,
            posterName = username,
            posterUser = username,
            title = title,
            description = description,
            reward = reward,
            kind = kind,
            status = "open",
            createdAt = os.epoch("utc"),
            updatedAt = os.epoch("utc"),
        }
        local minId = 100000
        local maxId = 999999
        local tries = 0
        local candidate = 0
        while true do
            candidate = math.random(minId, maxId)
            if not findJob(state, candidate) then job.id = candidate break end
            tries = tries + 1
            if tries > 1000 then
                candidate = candidate + 1
                if candidate > maxId then candidate = minId end
                if not findJob(state, candidate) then job.id = candidate break end
            end
        end
        state.nextId = candidate + 1
        state.jobs[candidate] = job
        local saved, saveError = saveState()
        if not saved then
            state.jobs[candidate] = nil
            state.nextId = candidate
            return { type = "error", message = saveError }
        end
        return { type = "job_created", job = copyJob(job) }
    end

    local function listJobs(senderId, username, mineOnly)
        local jobs = {}
        for _, job in pairs(state.jobs) do
            local isMine = belongsToUser(job, "posterUser", "posterId", senderId, username)
                or belongsToUser(job, "claimantUser", "claimantId", senderId, username)
            if mineOnly and isMine or not mineOnly and job.status == "open" then
                table.insert(jobs, copyJob(job))
            end
        end
        return { type = mineOnly and "my_jobs" or "job_board", jobs = jobs }
    end

    local function handleRequest(senderId, username, message)
        if type(message) ~= "table" or type(message.type) ~= "string" then
            return { type = "error", message = "Invalid Jobs request." }
        end
        if message.type == "jobs_capabilities" then
            return { type = "jobs_capabilities", serviceOffers = true }
        end
        if message.type == "list_jobs" then return listJobs(senderId, username, false) end
        if message.type == "my_jobs" then return listJobs(senderId, username, true) end
        if message.type == "create_job" then return createJob(senderId, username, message) end

        if type(message.jobId) ~= "number" or message.jobId % 1 ~= 0 then
            return { type = "error", message = "Enter a valid job number." }
        end
        local job = findJob(state, message.jobId)
        if not job then return { type = "error", message = "Job not found." } end
        local isPoster = belongsToUser(job, "posterUser", "posterId", senderId, username)
        local isClaimant = belongsToUser(job, "claimantUser", "claimantId", senderId, username)
        local isWorker = job.kind == "offer" and isPoster or job.kind ~= "offer" and isClaimant
        local isCustomer = job.kind == "offer" and isClaimant or job.kind ~= "offer" and isPoster

        if message.type == "claim_job" then
            if job.status ~= "open" then
                return { type = "error", message = "That job is no longer open." }
            end
            if isPoster then
                return { type = "error", message = "You cannot claim your own job." }
            end
            return mutateJob(senderId, job, {
                claimantId = senderId,
                claimantName = username,
                claimantUser = username,
                status = "claimed",
            }, "job_updated", { "submission", "reviewNote" })
        elseif message.type == "submit_job" then
            local submission = cleanText(message.submission, 5, 180)
            if not isWorker or job.status ~= "claimed" then
                return { type = "error", message = "Only the assigned worker can submit a claimed job." }
            end
            if not submission then
                return { type = "error", message = "Describe the completed work (5-180 characters)." }
            end
            return mutateJob(senderId, job, {
                submission = submission, status = "review",
            }, "job_updated", { "reviewNote" })
        elseif message.type == "approve_job" then
            if not isCustomer or job.status ~= "review" then
                return { type = "error", message = "Only the customer can approve submitted work." }
            end
            return mutateJob(senderId, job, { status = "completed" }, "job_updated")
        elseif message.type == "revise_job" then
            local note = cleanText(message.note, 1, 120)
            if not isCustomer or job.status ~= "review" then
                return { type = "error", message = "Only the customer can request a revision." }
            end
            if not note then
                return { type = "error", message = "Enter a revision note (1-120 characters)." }
            end
            return mutateJob(senderId, job, {
                status = "claimed", reviewNote = note,
            }, "job_updated", { "submission" })
        elseif message.type == "withdraw_claim" then
            if not isClaimant or job.status ~= "claimed" then
                return { type = "error", message = "You can only withdraw a job before submitting it." }
            end
            return mutateJob(senderId, job, {
                status = "open",
            }, "job_updated", { "claimantId", "claimantName", "claimantUser", "reviewNote", "submission" })
        elseif message.type == "cancel_job" then
            if not isPoster or (job.status ~= "open" and job.status ~= "claimed") then
                return { type = "error", message = "Only the poster can cancel an open or claimed job." }
            end
            return mutateJob(senderId, job, { status = "cancelled" }, "job_updated")
        end
        return { type = "error", message = "Unknown Jobs request." }
    end
    return handleRequest, cleanupJobs
end

return createJobsServer
