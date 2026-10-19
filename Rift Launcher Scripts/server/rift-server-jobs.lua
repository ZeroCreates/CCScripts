local function cleanText(value, minimum, maximum)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if #value < minimum or #value > maximum or value:find("%c") then return nil end
    return value
end

local function findJob(state, jobId)
    for _, job in ipairs(state.jobs) do
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
    local function mutateJob(senderId, job, changes, responseType)
        local previous = copyJob(job)
        for key, value in pairs(changes) do job[key] = value end
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
        local description = cleanText(message.description, 5, 180)
        local reward = cleanText(message.reward, 1, 60)
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
            status = "open",
            createdAt = os.epoch("utc"),
            updatedAt = os.epoch("utc"),
        }
        state.nextId = state.nextId + 1
        table.insert(state.jobs, job)
        local saved, saveError = saveState()
        if not saved then
            table.remove(state.jobs)
            state.nextId = state.nextId - 1
            return { type = "error", message = saveError }
        end
        return { type = "job_created", job = copyJob(job) }
    end

    local function listJobs(senderId, username, mineOnly)
        local jobs = {}
        for _, job in ipairs(state.jobs) do
            local isMine = belongsToUser(job, "posterUser", "posterId", senderId, username)
                or belongsToUser(job, "claimantUser", "claimantId", senderId, username)
            if mineOnly and isMine or not mineOnly and job.status == "open" then
                table.insert(jobs, copyJob(job))
            end
        end
        return { type = mineOnly and "my_jobs" or "job_board", jobs = jobs }
    end

    return function(senderId, username, message)
        if type(message) ~= "table" or type(message.type) ~= "string" then
            return { type = "error", message = "Invalid Jobs request." }
        end
        if message.type == "list_jobs" then return listJobs(senderId, username, false) end
        if message.type == "my_jobs" then return listJobs(senderId, username, true) end
        if message.type == "create_job" then return createJob(senderId, username, message) end

        if type(message.jobId) ~= "number" or message.jobId % 1 ~= 0 then
            return { type = "error", message = "Enter a valid job number." }
        end
        local job = findJob(state, message.jobId)
        if not job then return { type = "error", message = "Job not found." } end

        if message.type == "claim_job" then
            if job.status ~= "open" then
                return { type = "error", message = "That job is no longer open." }
            end
            if belongsToUser(job, "posterUser", "posterId", senderId, username) then
                return { type = "error", message = "You cannot claim your own job." }
            end
            return mutateJob(senderId, job, {
                claimantId = senderId,
                claimantName = username,
                claimantUser = username,
                status = "claimed",
                submission = nil,
                reviewNote = nil,
            }, "job_updated")
        elseif message.type == "submit_job" then
            local submission = cleanText(message.submission, 5, 180)
            if not belongsToUser(job, "claimantUser", "claimantId", senderId, username)
                or job.status ~= "claimed" then
                return { type = "error", message = "Only the assigned worker can submit a claimed job." }
            end
            if not submission then
                return { type = "error", message = "Describe the completed work (5-180 characters)." }
            end
            return mutateJob(senderId, job, {
                submission = submission, reviewNote = nil, status = "review",
            }, "job_updated")
        elseif message.type == "approve_job" then
            if not belongsToUser(job, "posterUser", "posterId", senderId, username)
                or job.status ~= "review" then
                return { type = "error", message = "Only the job poster can approve submitted work." }
            end
            return mutateJob(senderId, job, { status = "completed" }, "job_updated")
        elseif message.type == "revise_job" then
            local note = cleanText(message.note, 1, 120)
            if not belongsToUser(job, "posterUser", "posterId", senderId, username)
                or job.status ~= "review" then
                return { type = "error", message = "Only the job poster can request a revision." }
            end
            if not note then
                return { type = "error", message = "Enter a revision note (1-120 characters)." }
            end
            return mutateJob(senderId, job, {
                status = "claimed", reviewNote = note, submission = nil,
            }, "job_updated")
        elseif message.type == "withdraw_claim" then
            if not belongsToUser(job, "claimantUser", "claimantId", senderId, username)
                or job.status ~= "claimed" then
                return { type = "error", message = "You can only withdraw a job before submitting it." }
            end
            return mutateJob(senderId, job, {
                claimantId = nil,
                claimantName = nil,
                claimantUser = nil,
                status = "open",
                reviewNote = nil,
            }, "job_updated")
        elseif message.type == "cancel_job" then
            if not belongsToUser(job, "posterUser", "posterId", senderId, username)
                or (job.status ~= "open" and job.status ~= "claimed") then
                return { type = "error", message = "Only the poster can cancel an open or claimed job." }
            end
            return mutateJob(senderId, job, { status = "cancelled" }, "job_updated")
        end
        return { type = "error", message = "Unknown Jobs request." }
    end
end

return createJobsServer
