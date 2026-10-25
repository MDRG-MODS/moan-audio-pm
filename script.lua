-- Moan Audio Personality Module
-- Plays custom OGG moan audio during frick scenes via dialogue branch hooks.
-- Custom audio is loaded with ModUtilities.GetAsAudioClipReference (added in
-- MDRG 0.95.5). Audio files are organized into 5 categories used to match
-- moan style to scene context.
--
-- Bot orgasm events (Frick_BotCumming, Frick_FingeringBotCumming) trigger a
-- multi-phase sequence (start clip → continuous moans → end clip) via a
-- supervisor coroutine. While the sequence is running, other dialogue
-- branches do not play their per-branch sounds (so the sequence isn't
-- drowned out by overlapping moans).

do

---------------------------------------------------------------------------
-- Item prefab
---------------------------------------------------------------------------
local itemprefab0 = ModUtilities.CreateItemPrefab()
itemprefab0.Name = 'Moan Audio Personality Module'
itemprefab0.Description = 'Plays custom moan audio during frick scenes.'
itemprefab0.Price = 10
itemprefab0.SlotData = SlotEquipData.CreateInstance('PersonalityModule')
itemprefab0.IsIllegal = true
itemprefab0.HasQuality = false
itemprefab0.ThrowingOutForbidden = false
itemprefab0.IsPersonalityModule = true
itemprefab0.IsStackable = false
itemprefab0.Category = ItemCategory.Modules
itemprefab0.CanChangeColor = false
itemprefab0.ColorSlots = {}
itemprefab0.Partners = {}
itemprefab0.ScratchType = ScratchTextureType.Universal
itemprefab0.SusModifiers = {}

local itemgameid0 = ModUtilities.CreateNewItemAutoAssignId(CurrentModGuid, itemprefab0)
ModUtilities.AddSingleBuyItemToShop('ladyparts.ic', itemgameid0)

---------------------------------------------------------------------------
-- Audio file paths
---------------------------------------------------------------------------
local AUDIO_FILES = {
    breath = {
        'moans/breath/Moaning breath 1.ogg',
        'moans/breath/Moaning breath 2.ogg',
        'moans/breath/Moaning breath 3.ogg',
        'moans/breath/Moaning breath 4.ogg',
    },
    while_frick = {
        'moans/while/Moan 4.ogg',
        'moans/while/Moan 5.ogg',
        'moans/while/Moan 6.ogg',
        'moans/while/Moan 7.ogg',
        'moans/while/Moan 8.ogg',
        'moans/while/Moan 9.ogg',
        'moans/while/Moan 12.ogg',
        'moans/while/Moan 15.ogg',
        'moans/while/Moan 17.ogg',
    },
    cumming_start = {
        'moans/cumming/start/Moan 10.ogg',
        'moans/cumming/start/Moan 11.ogg',
        'moans/cumming/start/Moan 13.ogg',
        'moans/cumming/start/Moan 14.ogg',
        'moans/cumming/start/Moan 20.ogg',
    },
    cumming_while = {
        'moans/cumming/while/Moaning 1.ogg',
        'moans/cumming/while/Moaning 2.ogg',
        'moans/cumming/while/Moaning 3.ogg',
        'moans/cumming/while/Moaning 4.ogg',
        'moans/cumming/while/Moaning 5.ogg',
        'moans/cumming/while/Moaning 6.ogg',
        'moans/cumming/while/Moaning 7.ogg',
        'moans/cumming/while/Moaning 8.ogg',
        'moans/cumming/while/Moaning goran 2.ogg',
        'moans/cumming/while/Moaning groan 1.ogg',
    },
    cumming_end = {
        'moans/cumming/end/Moan 2.ogg',
        'moans/cumming/end/Moan 3.ogg',
        'moans/cumming/end/Moan 16.ogg',
    },
}

---------------------------------------------------------------------------
-- Audio loading
---------------------------------------------------------------------------
-- AudioClips are pre-resolved here in the main Lua context. GetResource()
-- cannot be called from inside SetOnActivateAction callbacks, so we resolve
-- everything upfront and store the actual AudioClip objects.

local clipsByCategory = {}
local audioAvailable = false

-- Moan volume. Base 0.5; with real brain state, scale 0.4 -> 0.65 by
-- Pleasure (0-1, from CurrentBrain.Pleasure) so she gets louder toward
-- climax. tune the 0.4/0.25 if it feels flat.
local function vol()
    if not _G.MoanModHasRealState then return 0.5 end
    return 0.4 + 0.25 * (_G.MoanModPleasure or 0)
end

local function buildClips()
    if not ModUtilities.GetAsAudioClipReference then
        print('[MoanMod] WARNING: GetAsAudioClipReference not found.')
        print('[MoanMod] This mod requires MDRG 0.95.5 or newer for audio.')
        print('[MoanMod] Dialogue will still work, just without sound.')
        return
    end

    local loaded, failed = 0, 0
    for catName, paths in pairs(AUDIO_FILES) do
        clipsByCategory[catName] = {}
        for _, path in ipairs(paths) do
            local refOk, ref = pcall(function()
                return ModUtilities.GetAsAudioClipReference(CurrentModGuid, path)
            end)
            if not refOk or not ref or ref.IsNull() then
                failed = failed + 1
                print('[MoanMod] Failed to get ref: ' .. path)
            else
                local clipOk, clip = pcall(function() return ref.GetResource() end)
                if clipOk and clip then
                    table.insert(clipsByCategory[catName], clip)
                    loaded = loaded + 1
                    audioAvailable = true
                else
                    failed = failed + 1
                    print('[MoanMod] GetResource failed for ' .. path)
                end
            end
        end
    end

    if audioAvailable then
        print('[MoanMod] Loaded ' .. loaded .. ' audio clips (' .. failed .. ' failed)')
    else
        print('[MoanMod] WARNING: No audio clips loaded (' .. failed .. ' failed)')
    end
end

---------------------------------------------------------------------------
-- Per-category playback actions
---------------------------------------------------------------------------
-- Each category action is a self-contained closure that picks a random
-- pre-loaded clip and plays it. Constraints:
--   * Closures invoked via SetOnActivateAction run in C# delegate context
--     where many things break. Keep them minimal.
--   * Single direct upvalue (the clips list) -- nested function calls and
--     complex upvalue chains have been observed to corrupt branch state.
--   * Skip playback if the bot cumming sequence is running so per-branch
--     sounds don't overlap with the multi-phase sequence.
--
-- Special case: cumming_start does NOT play a single clip. It just sets a
-- global flag, which the supervisor coroutine picks up and uses to run the
-- full multi-phase sequence.

local categoryActions = {}

local function buildCategoryActions()
    for catName, clips in pairs(clipsByCategory) do
        local localClips = clips
        if #localClips > 0 then
            categoryActions[catName] = function()
                if _G.MoanModSequenceRunning then return end
                local clip = localClips[math.random(#localClips)]
                SoundSingleton.Play(clip, vol(), nil)
            end
        end
    end

    categoryActions.cumming_start = function()
        if _G.MoanModSequenceRunning then return end
        -- With live state, the IsCumming rising edge starts the sequence at
        -- the real moment. This dialogue line fires when she *announces* it
        -- (too early), so only use it as the trigger when live state is absent.
        if not _G.MoanModHasRealState then
            _G.MoanModBotCummingTrigger = true
        end
    end
end

---------------------------------------------------------------------------
-- Bot cumming sequence supervisor
---------------------------------------------------------------------------
-- Watches a global flag set by the cumming_start action. When triggered,
-- runs a three-phase moan sequence: startup → continuous → conclusion.
-- The supervisor sets MoanModSequenceRunning so other dialogue branches
-- skip their per-branch sounds while the sequence is playing.

local function startCummingSupervisor()
    if not audioAvailable then return end

    local startClips = clipsByCategory.cumming_start or {}
    local whileClips = clipsByCategory.cumming_while or {}
    local endClips = clipsByCategory.cumming_end or {}
    local breathClips = clipsByCategory.breath or {}
    local sexClips = clipsByCategory.while_frick or {}

    if #startClips == 0 and #whileClips == 0 and #endClips == 0 then
        print('[MoanMod] No cumming clips loaded, supervisor not started')
        return
    end

    _G.MoanModBotCummingTrigger = false
    _G.MoanModSequenceRunning = false
    _G.MoanModBotIsCumming = false
    _G.MoanModHasRealState = false  -- true while we can read the bot's live state
    _G.MoanModPleasure = 0          -- 0-1 arousal, polled from CurrentBrain.Pleasure
    _G.MoanModFingering = false     -- fingering active/recent, from InteractionMemory

    -- Poll the live bot controller directly via the singleton (0.97.1+).
    -- We do NOT use an item modifier: MoonSharp can't convert a Lua function
    -- to the Func`3 that ItemModiferAdditionFunction wants, so we read state
    -- from this coroutine instead. Sets the MoanMod* globals; returns true if
    -- the live state was readable.
    local loggedRealState = false
    local function pollState()
        local ok, c = pcall(function()
            return Live2DControllerSingleton.LuaInstance.GetReadyController('bot')
        end)
        local okC, cumming
        if ok and c then okC, cumming = pcall(function() return c.Expression.IsCumming end) end
        if not (ok and c and okC) then
            -- No live state (e.g. you left the scene): clear everything so
            -- stale values can't drive sounds outside of sex.
            _G.MoanModHasRealState = false
            _G.MoanModBotIsCumming = false
            _G.MoanModFingering = false
            _G.MoanModPleasure = 0
            return false
        end
        _G.MoanModHasRealState = true
        _G.MoanModBotIsCumming = cumming
        local okP, p = pcall(function() return c.CurrentBrain.Pleasure end)
        _G.MoanModPleasure = (okP and p) or 0
        local okF, f = pcall(function()
            return c.CurrentBrain.InteractionMemory
                .GetComplexMemory(InteractionMemoryEnum.Fingering).IsActiveOrRecent()
        end)
        _G.MoanModFingering = okF and f or false
        if not loggedRealState then
            loggedRealState = true
            print('[MoanMod] Real bot state active (controller found, IsCumming readable)')
        end
        return true
    end

    local function supervisor()
        local wasCumming = false
        while true do
            local hasState = pollState()
            -- Rising edge of IsCumming starts the sequence (accurate). Without
            -- real state, the dialogue "cumming_start" branch sets the trigger.
            -- Rising edge only counts while we have live state. If state is
            -- lost (you left the scene), leave wasCumming untouched so a stuck
            -- or re-reported 'cumming' after returning can't replay the climax.
            local edge = false
            if hasState then
                local cumming = _G.MoanModBotIsCumming
                edge = cumming and not wasCumming
                wasCumming = cumming
            end

            if _G.MoanModBotCummingTrigger or edge then
                _G.MoanModBotCummingTrigger = false
                _G.MoanModSequenceRunning = true
                print('[MoanMod] Bot cumming sequence: START')

                -- Phase 1: startup moan
                if #startClips > 0 then
                    local clip = startClips[math.random(#startClips)]
                    SoundSingleton.Play(clip, vol(), nil)
                    coroutine.yield(ModUtilities.WaitForSeconds(clip.length + 0.1))
                end

                -- Phase 2: continuous moans, no overlap. With real state,
                -- loop until she actually stops cumming (synced to the
                -- animation). Otherwise fall back to a 4-6s guess.
                local totalDuration = 4 + math.random() * 2
                local elapsed = 0
                local leftScene = false
                while #whileClips > 0 do
                    if hasState then
                        if not pollState() then leftScene = true break end  -- left the scene
                        if not _G.MoanModBotIsCumming then break end          -- done cumming
                    elseif elapsed >= totalDuration then
                        break
                    end
                    local clip = whileClips[math.random(#whileClips)]
                    SoundSingleton.Play(clip, vol(), nil)
                    -- Higher pleasure = shorter gaps (more frantic). Scales
                    -- the pause down to ~40% at full arousal; no-op if no real state.
                    local pace = 1 - 0.6 * (_G.MoanModPleasure or 0)
                    local pause = (0.05 + math.random() * 0.15) * pace
                    local wait = clip.length + pause
                    coroutine.yield(ModUtilities.WaitForSeconds(wait))
                    elapsed = elapsed + wait
                end

                -- Phase 3: conclusion moan -- skipped if she left the scene
                -- mid-cum, so the climax sound never plays outside of sex.
                if not leftScene and #endClips > 0 then
                    local clip = endClips[math.random(#endClips)]
                    SoundSingleton.Play(clip, vol(), nil)
                    coroutine.yield(ModUtilities.WaitForSeconds(clip.length + 0.1))
                end

                _G.MoanModSequenceRunning = false
                print('[MoanMod] Bot cumming sequence: END')
            elseif hasState and (_G.MoanModPleasure or 0) > 0.85
                   and not _G.MoanModBotIsCumming and #sexClips > 0 then
                -- Near-climax cue: urgent moans as she nears the edge
                -- (pleasure >0.85 but not yet cumming). The 0.85
                -- threshold, tune to taste. This is the doable half of
                -- pleasure-gated selection -- true low/mid/high buckets need
                -- the while/ clips tagged by intensity, which we don't have.
                local clip = sexClips[math.random(#sexClips)]
                SoundSingleton.Play(clip, vol(), nil)
                coroutine.yield(ModUtilities.WaitForSeconds(clip.length + 0.1 + math.random() * 0.3))
            elseif _G.MoanModFingering and #breathClips > 0 then
                -- Ambient breathing while she's being fingered (0.97.1
                -- InteractionMemory). Low volume, faster/louder with pleasure.
                -- overlaps quietly under other moans by design.
                local clip = breathClips[math.random(#breathClips)]
                SoundSingleton.Play(clip, 0.3 * (0.6 + 0.4 * (_G.MoanModPleasure or 0)), nil)
                local gap = (1.5 + math.random()) * (1 - 0.5 * (_G.MoanModPleasure or 0))
                coroutine.yield(ModUtilities.WaitForSeconds(clip.length + gap))
            end

            coroutine.yield(ModUtilities.WaitForSeconds(0.1))
        end
    end

    ModUtilities.StartCoroutine(supervisor)
    print('[MoanMod] Cumming supervisor started (polling live bot state)')
end

---------------------------------------------------------------------------
-- Initialize audio system
---------------------------------------------------------------------------
buildClips()
buildCategoryActions()
startCummingSupervisor()

---------------------------------------------------------------------------
-- Moan hooks
---------------------------------------------------------------------------
-- One branch per event. Each carries a short moan line -- an EMPTY branch is
-- invalid and makes the whole module fail to activate ("No missing found!" per
-- branch, then an activation exception). The line fires the matching category
-- moan audio on activation.

local EVENT_CATEGORY = {
    Blowjob_EdgingAlmostCame = 'breath',
    Blowjob_EdgingForceStop = 'breath',
    Blowjob_EdgingHadToSlowdown = 'breath',
    Blowjob_SwallowAlmostEmpty = 'breath',
    Blowjob_SwallowFull = 'cumming_while',
    Blowjob_SwallowHalf = 'cumming_while',
    Blowjob_SwallowLittle = 'cumming_while',
    Blowjob_SwallowWithMl = 'cumming_while',
    Blowjob_SwitchToCowgirlBotLead = 'breath',
    Blowjob_SwitchToCowgirlBotRape = 'while_frick',
    Cowgirl_AfterFirstInsertBotRape = 'while_frick',
    Cowgirl_BeforeFirstInsert = 'breath',
    Cowgirl_BeforeFirstInsertBotLead = 'breath',
    Cowgirl_BeforeFirstInsertRape = 'while_frick',
    Cowgirl_BeforeSwitchToBlowjobBotLead = 'breath',
    Cowgirl_BeforeSwitchToBlowjobRape = 'while_frick',
    Cowgirl_EdgingBreak = 'while_frick',
    Cowgirl_EdgingForceStopped = 'breath',
    Cowgirl_FlacidReaction = 'cumming_end',
    Cowgirl_MadeMcCumInsideWhileCummingHerself = 'cumming_end',
    Cowgirl_RemovePants = 'breath',
    Cowgirl_WhereToCumQuestion = 'while_frick',
    Cowgirl_WhereToCumQuestionDidntAnswer = 'breath',
    Frick_BoobFondle = 'breath',
    Frick_BotCumming = 'cumming_start',
    Frick_ClitRub = 'while_frick',
    Frick_CumInside = 'cumming_end',
    Frick_CumInsideAnal = 'cumming_end',
    Frick_CumOutside = 'cumming_end',
    Frick_CumThighjob = 'cumming_end',
    Frick_CumTogether = 'cumming_end',
    Frick_EdgingOff = 'breath',
    Frick_EdgingOn = 'breath',
    Frick_FingeringBotCumming = 'cumming_start',
    Frick_FingeringDuring = 'while_frick',
    Frick_FlacidBoredReaction = 'cumming_end',
    Frick_GenericFuckBrainStateRandomDialogueCockInside = 'while_frick',
    Frick_GenericFuckBrainStateRandomDialogueCockInsideAnal = 'while_frick',
    Frick_GenericFuckBrainStateRandomDialogueCockOutside = 'breath',
    Frick_Handholding = 'breath',
    Frick_Headpat = 'breath',
    Frick_Moan = 'while_frick',
    Frick_NipplePull = 'breath',
    Frick_PussySpread = 'breath',
    Frick_RapeBegStopRefuse = 'while_frick',
    Frick_RapeBegStopSuccess = 'breath',
    Frick_RapeFlacidReaction = 'cumming_end',
    Frick_StartFrick = 'breath',
    Frick_UpsetOnlySheMoves = 'while_frick',
}

-- Short moan line per category (kept minimal; the audio carries the variety).
local MOAN_TEXT = {
    breath        = 'Mm~',
    while_frick   = 'Ah~',
    cumming_start = 'Aah~!',
    cumming_while = 'Mmm~!',
    cumming_end   = 'Haa~',
}

local personality = ModUtilities.PrepareNewPersonalityDefinition()
local idx = 0

local function buildDialogue()
    local branchCount = 0
    for tag, category in pairs(EVENT_CATEGORY) do
        local container = personality.PrepareContainer(tag)
        local branch = StoryBotDialogueBranch.__new('Bot: ' .. (MOAN_TEXT[category] or 'Mm~'), CurrentModGuid, idx)
        container.AddBranch(branch)
        branchCount = branchCount + 1
        if audioAvailable and categoryActions[category] then
            branch.SetOnActivateAction(categoryActions[category])
        end
        idx = idx + 1
    end
    print('[MoanMod] Built ' .. branchCount .. ' moan hooks')
end

buildDialogue()

---------------------------------------------------------------------------
-- Bind personality to item
---------------------------------------------------------------------------
itemprefab0.TurnIntoPersonalityModule(itemgameid0, personality)

end
