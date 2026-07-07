	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")

	local require = (getrenv and getrenv().require) or require

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local charge = require(ReplicatedStorage.Modules.Touch.Charge)
	local options = require(ReplicatedStorage.Modules.Options)
	local touchRemote = ReplicatedStorage.Remotes.Game.Touch
	local NebulaUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/lozanobrian669/nebula-ui/refs/heads/main/library.lua"))()

	-- ====================================================================
	-- SINGLETON: al re-ejecutar el script, descargar la instancia anterior
	-- (cada ejecución carga su propia copia de NebulaUI, así que DestroyAll
	-- no ve las ventanas viejas; esto las limpia junto con sus conexiones)
	-- ====================================================================
	local ENV = (getgenv and getgenv()) or _G
	if ENV.TouchlineReachUnload then
		pcall(ENV.TouchlineReachUnload)
		ENV.TouchlineReachUnload = nil
	end
	-- Red de seguridad para restos de versiones sin unload
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and (gui.Name:match("^NebulaUI_%d+$") or gui.Name == "TouchlineReachDebugUI") then
			gui:Destroy()
		end
	end
	pcall(function()
		local oldDebug = workspace.Terrain:FindFirstChild("TouchlineReachDebug")
		if oldDebug then
			oldDebug:Destroy()
		end
	end)

	local REACH_MIN_STUDS = 4
	local REACH_MAX_STUDS = 50
	local HEIGHT_MIN_STUDS = 5
	local HEIGHT_MAX_STUDS = 18
	local OBSERVED_ACTION_WINDOW = 1.25

	local reachStuds = REACH_MIN_STUDS
	local heightStuds = HEIGHT_MIN_STUDS
	local customSpeed = 16
	local speedEnabled = false
	local reachDebugPart = nil
	local touchedBalls = {}
	local observedAction = nil
	local observedActionAt = 0
	local activeScanAction = nil
	local activeScanOffset = CFrame.new(0, 0, 0)
	local activeScanUntil = 0
	local nativeHookApplied = false

	-- Estado para poder descargar esta instancia en la próxima ejecución
	local connections = {}
	local hookedTouchModule = nil
	local originalDetectRef = nil
	local originalTackleRef = nil

	local function publishReach()
		heightStuds = HEIGHT_MIN_STUDS + (reachStuds - REACH_MIN_STUDS) * ((HEIGHT_MAX_STUDS - HEIGHT_MIN_STUDS) / (REACH_MAX_STUDS - REACH_MIN_STUDS))
		player:SetAttribute("TouchlineReachStuds", reachStuds)
		player:SetAttribute("TouchlineReachHeight", heightStuds)
	end

	local function getCharacter()
		local characters = workspace:FindFirstChild("Characters")
		return player.Character or characters and characters:FindFirstChild(player.Name)
	end

	local function getRoot()
		local character = getCharacter()
		if not character then
			return nil
		end

		return character:FindFirstChild("HumanoidRootPart")
	end

	local function getHumanoid()
		local character = getCharacter()
		if not character then
			return nil
		end

		return character:FindFirstChild("Humanoid")
	end

	local function getTouchFlags()
		local toggles = playerGui.Main.Game.Toggles

		return {
			Ground = toggles.Ground.Visible,
			Right = toggles.Right.Visible,
			Left = toggles.Left.Visible,
		}
	end

	local function isGameActive()
		local main = playerGui:FindFirstChild("Main")
		local values = main and main:FindFirstChild("Values")
		if not values then
			return false
		end
		
		local inMenu = values:FindFirstChild("InMenu")
		local active = values:FindFirstChild("Active")
		local ragdoll = values:FindFirstChild("Ragdoll")
		
		return (inMenu and inMenu.Value == false) 
			and (active and active.Value == true) 
			and (ragdoll and ragdoll.Value == false)
	end

	local function getChargeAction()
		local values = playerGui.Main.Values

		if charge.Get() <= 0.3 then
			return values.Goalie.Value == true and "Save" or "Dribble"
		end

		return "Shoot"
	end

	local function getTackleAction()
		local values = playerGui.Main.Values
		return values.Goalie.Value == true and values.Diving.Value == true and "Dive" or "Tackle"
	end

	local function getMoveDirectionName()
		local character = getCharacter()
		local root = getRoot()
		local humanoid = getHumanoid()

		if not character or not root or not humanoid then
			return "Idle"
		end

		local localMoveDirection = root.CFrame:VectorToObjectSpace(humanoid.MoveDirection)
		if localMoveDirection.Magnitude < 0.1 then
			return humanoid.FloorMaterial == Enum.Material.Air and "Jump" or "Idle"
		end

		if math.abs(localMoveDirection.Z) < math.abs(localMoveDirection.X) then
			return localMoveDirection.X > 0 and "Right" or "Left"
		end

		return localMoveDirection.Z > 0 and "Backward" or "Forward"
	end

	local function getActionOffset(actionName)
		if actionName == "Shoot" then
			return CFrame.new(0, -0.5, 0)
		end

		if actionName == "Tackle" then
			return CFrame.new(0, -1.75, -0.5)
		end

		if actionName == "Dive" then
			local directionName = getMoveDirectionName()
			if directionName == "Forward" then
				return CFrame.new(0, -1.5, -0.5)
			elseif directionName == "Jump" then
				return CFrame.new(0, 0.5, 0)
			end

			return CFrame.new(0, 0, 0)
		end

		return CFrame.new(0, -0.5, -0.25)
	end

	local function getActionDuration(actionName)
		if actionName == "Shoot" then
			return 0.5
		elseif actionName == "Dribble" then
			return 0.75
		end

		return 1
	end

	local function startActionScan(actionName)
		activeScanAction = actionName
		activeScanOffset = getActionOffset(actionName)
		activeScanUntil = tick() + getActionDuration(actionName)
		touchedBalls = {}
	end

	local function rememberAction(actionName)
		observedAction = actionName
		observedActionAt = tick()
		startActionScan(actionName)
	end

	local function getObservedAction()
		if observedAction and tick() - observedActionAt <= OBSERVED_ACTION_WINDOW then
			return observedAction
		end

		return nil
	end

	local function inferAction()
		if activeScanAction and tick() <= activeScanUntil then
			return activeScanAction
		end

		local action = getObservedAction()
		if action then
			return action
		end

		local values = playerGui.Main.Values
		local humanoid = getHumanoid()
		local isTackleWindow = humanoid and humanoid.WalkSpeed >= 34

		if isTackleWindow then
			if values.Goalie.Value == true and values.Diving.Value == true then
				return "Dive"
			end

			return "Tackle"
		end

		return getChargeAction()
	end

	local function getReachCFrame(offset)
		local root = getRoot()
		if not root then
			return nil
		end

		return root.CFrame * (offset or CFrame.new(0, 0, 0))
	end

	local function getReachSize()
		return Vector3.new(reachStuds, heightStuds, reachStuds)
	end

	local function clearReachDebug()
		if reachDebugPart then
			reachDebugPart:Destroy()
			reachDebugPart = nil
		end
	end

	local function updateReachDebug(cframe)
		local root = getRoot()
		if not root then
			clearReachDebug()
			return
		end

		-- Verificar si el weld de la parte de debug sigue conectado al root actual del personaje
		if reachDebugPart then
			local weld = reachDebugPart:FindFirstChildOfClass("WeldConstraint")
			if not weld or weld.Part0 ~= root or weld.Part1 ~= reachDebugPart then
				clearReachDebug()
			end
		end

		if not reachDebugPart then
			reachDebugPart = Instance.new("Part")
			reachDebugPart.Name = "TouchlineReachDebug"
			reachDebugPart.CanCollide = false
			reachDebugPart.CanTouch = false
			reachDebugPart.CanQuery = false
			reachDebugPart.Massless = true
			reachDebugPart.Anchored = false
			reachDebugPart.CastShadow = false
			reachDebugPart.Transparency = 0.78
			reachDebugPart.Color = Color3.fromRGB(255, 185, 55)
			reachDebugPart.Material = Enum.Material.Neon
			reachDebugPart.Parent = workspace.Terrain

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = reachDebugPart
			weld.Parent = reachDebugPart
		end

		reachDebugPart.Size = getReachSize()
		reachDebugPart.CFrame = cframe
	end

	local function fireTouch(ball)
		local character = getCharacter()
		local root = getRoot()
		local humanoid = getHumanoid()

		if not character or not root or not humanoid then
			return
		end

		local data = {
			ball,
			inferAction(),
			math.floor(charge.Get() * 100) / 100,
			getTouchFlags(),
			root.CFrame,
			humanoid.MoveDirection, -- Enviar MoveDirection en espacio de mundo para coincidir con touchline.lua
		}

		task.spawn(function()
			local ok, result = pcall(function()
				return touchRemote:InvokeServer(data)
			end)
			if ok then
				pcall(function()
					local TouchModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Touch"))
					if TouchModule and TouchModule.Confirm then
						TouchModule.Confirm(result)
					end
				end)
			end
		end)
		touchRemote.Kick:FireServer(data)
	end

	local function scanReach(offset)
		local cframe = getReachCFrame(offset)
		if not cframe then
			clearReachDebug()
			return
		end

		updateReachDebug(cframe)

		for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, getReachSize(), nil)) do
			if part.Name == "Ball" and part.Anchored == false and not touchedBalls[part] then
				touchedBalls[part] = true
				fireTouch(part)
			end
		end
	end

	-- ====================================================================
	-- SISTEMA DE NOTIFICACIONES PERSONALIZADO (Estilo NebulaUI)
	-- ====================================================================
	local activeNotifications = {}
	
	local function repositionNotifications()
		local TweenService = game:GetService("TweenService")
		for i, toast in ipairs(activeNotifications) do
			local offset = (i - 1) * 72
			TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(1, -280, 0.9, -70 - offset)
			}):Play()
		end
	end

	local function showNotification(title, text)
		for _, activeToast in ipairs(activeNotifications) do
			local textLabel = activeToast:FindFirstChild("Content")
			if textLabel and textLabel.Text == text then
				return
			end
		end

		local screen = playerGui:FindFirstChild("TouchlineReachDebugUI")
		if not screen then
			screen = Instance.new("ScreenGui")
			screen.Name = "TouchlineReachDebugUI"
			screen.ResetOnSpawn = false
			screen.Parent = playerGui
		end
		
		local accentColor = NebulaUI and NebulaUI.Theme.Accent or Color3.fromRGB(155, 93, 229)
		
		local toast = Instance.new("Frame")
		toast.Name = "Notification"
		toast.Size = UDim2.fromOffset(260, 64)
		toast.BackgroundColor3 = NebulaUI.Theme.SidebarBackground
		toast.BorderSizePixel = 0
		toast.ClipsDescendants = true
		toast.Parent = screen
		
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = toast
		
		local accentBar = Instance.new("Frame")
		accentBar.Size = UDim2.new(0, 4, 1, 0)
		accentBar.Position = UDim2.new(0, 0, 0, 0)
		accentBar.BackgroundColor3 = accentColor
		accentBar.BorderSizePixel = 0
		accentBar.Parent = toast
		
		local titleLabel = Instance.new("TextLabel")
		titleLabel.Size = UDim2.new(1, -24, 0, 20)
		titleLabel.Position = UDim2.new(0, 16, 0, 8)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.Text = title
		titleLabel.TextColor3 = Color3.fromRGB(245, 245, 245)
		titleLabel.TextSize = 12
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Parent = toast
		
		local textLabel = Instance.new("TextLabel")
		textLabel.Name = "Content"
		textLabel.Size = UDim2.new(1, -24, 0, 28)
		textLabel.Position = UDim2.new(0, 16, 0, 26)
		textLabel.BackgroundTransparency = 1
		textLabel.Font = Enum.Font.Gotham
		textLabel.Text = text
		textLabel.TextColor3 = Color3.fromRGB(170, 170, 175)
		textLabel.TextSize = 10
		textLabel.TextXAlignment = Enum.TextXAlignment.Left
		textLabel.TextWrapped = true
		textLabel.Parent = toast

		local TweenService = game:GetService("TweenService")
		
		if #activeNotifications >= 3 then
			local oldest = table.remove(activeNotifications, 1)
			local slideOut = TweenService:Create(oldest, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(1, 300, oldest.Position.Y.Scale, oldest.Position.Y.Offset)
			})
			slideOut:Play()
			slideOut.Completed:Connect(function()
				oldest:Destroy()
			end)
		end
		
		table.insert(activeNotifications, toast)
		
		local offset = (#activeNotifications - 1) * 72
		toast.Position = UDim2.new(1, 300, 0.9, -70 - offset)
		
		TweenService:Create(toast, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(1, -280, 0.9, -70 - offset)
		}):Play()
		
		task.delay(3.5, function()
			local idx = table.find(activeNotifications, toast)
			if idx then
				table.remove(activeNotifications, idx)
				repositionNotifications()
				
				local slideOut = TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Position = UDim2.new(1, 300, toast.Position.Y.Scale, toast.Position.Y.Offset)
				})
				slideOut:Play()
				slideOut.Completed:Connect(function()
					toast:Destroy()
				end)
			end
		end)
	end


	local function isTacklingOrDiving()
		local humanoid = getHumanoid()
		if not humanoid then return false end

		local animator = humanoid:FindFirstChild("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				local animName = string.lower(track.Animation.Name)
				if animName == "tackle" or animName == "dive" or animName == "save" or animName == "slide" then
					return true
				end
			end
		end

		return false
	end

	-- ====================================================================
	-- PESTAÑA INICIO (contenedor único con tarjetas estilo glasmorfismo)
	-- ====================================================================
	-- Labels con color de acento del Inicio: UpdateTheme no los conoce,
	-- así que se registran acá para recolorearlos al cambiar el tema
	local homeAccentLabels = {}

	local function createHomeCard(parent, layoutOrder)
		local card = Instance.new("Frame")
		card.Name = "HomeCard"
		card.Size = UDim2.new(1, 0, 0, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.LayoutOrder = layoutOrder
		card.BackgroundColor3 = NebulaUI.Theme.CardBackground
		card.BackgroundTransparency = 0.25
		card.BorderSizePixel = 0
		card.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = card

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.86
		stroke.Thickness = 1
		stroke.Parent = card

		local sheen = Instance.new("UIGradient")
		sheen.Rotation = 90
		sheen.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(195, 195, 205))
		sheen.Parent = card

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 10)
		padding.PaddingBottom = UDim.new(0, 12)
		padding.PaddingLeft = UDim.new(0, 14)
		padding.PaddingRight = UDim.new(0, 12)
		padding.Parent = card

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 3)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = card

		return card
	end

	local function addHomeLabel(card, layoutOrder, text, font, textSize, color)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.LayoutOrder = layoutOrder
		label.BackgroundTransparency = 1
		label.Font = font
		label.Text = text
		label.TextColor3 = color
		label.TextSize = textSize
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = true
		label.Parent = card
		return label
	end

	local function addHomeSpacer(card, layoutOrder, spacerHeight)
		local spacer = Instance.new("Frame")
		spacer.Size = UDim2.new(1, 0, 0, spacerHeight)
		spacer.LayoutOrder = layoutOrder
		spacer.BackgroundTransparency = 1
		spacer.Parent = card
	end

	local function buildHomeTab(tab, t, isMobile)
		local headerSize = isMobile and 9 or 10
		local titleSize = isMobile and 12 or 13
		local entrySize = isMobile and 10 or 11
		local bodySize = isMobile and 9 or 10

		homeAccentLabels = {}

		local container = Instance.new("Frame")
		container.Name = "HomeContainer"
		container.Size = UDim2.new(0.95, 0, 0, 0)
		container.BackgroundTransparency = 1
		container.LayoutOrder = 1
		container.Parent = tab.ContentFrame

		-- Columna izquierda: Acerca de + Changelog
		local leftColumn = Instance.new("Frame")
		leftColumn.Name = "LeftColumn"
		leftColumn.Size = UDim2.new(isMobile and 1 or 0.6, 0, 0, 0)
		leftColumn.AutomaticSize = Enum.AutomaticSize.Y
		leftColumn.BackgroundTransparency = 1
		leftColumn.Parent = container

		local leftLayout = Instance.new("UIListLayout")
		leftLayout.Padding = UDim.new(0, 8)
		leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
		leftLayout.Parent = leftColumn

		-- Card 1: Acerca de
		local aboutCard = createHomeCard(leftColumn, 1)
		table.insert(homeAccentLabels, addHomeLabel(aboutCard, 1, string.upper(t.HomeAboutSection), Enum.Font.GothamBold, headerSize, NebulaUI.Theme.Accent))
		addHomeSpacer(aboutCard, 2, 2)
		addHomeLabel(aboutCard, 3, t.HomeAboutTitle, Enum.Font.GothamBold, titleSize, NebulaUI.Theme.Text)
		addHomeLabel(aboutCard, 4, t.HomeAboutDesc, Enum.Font.Gotham, bodySize, NebulaUI.Theme.MutedText)

		-- Card 2: Changelog (debajo de Acerca de)
		local changelogCard = createHomeCard(leftColumn, 2)
		table.insert(homeAccentLabels, addHomeLabel(changelogCard, 1, string.upper(t.HomeChangelogSection), Enum.Font.GothamBold, headerSize, NebulaUI.Theme.Accent))
		local order = 2
		for _, entry in ipairs(t.HomeChangelog) do
			addHomeSpacer(changelogCard, order, 4)
			addHomeLabel(changelogCard, order + 1, entry.Title, Enum.Font.GothamBold, entrySize, NebulaUI.Theme.Text)
			addHomeLabel(changelogCard, order + 2, entry.Desc, Enum.Font.Gotham, bodySize, NebulaUI.Theme.MutedText)
			order = order + 3
		end

		-- Card 3: Créditos (columna derecha en PC, ocupa toda la altura; abajo en mobile)
		local creditsCard = createHomeCard(isMobile and leftColumn or container, 3)
		table.insert(homeAccentLabels, addHomeLabel(creditsCard, 1, string.upper(t.HomeCreditsSection), Enum.Font.GothamBold, headerSize, NebulaUI.Theme.Accent))
		order = 2
		for _, member in ipairs(t.HomeCredits) do
			addHomeSpacer(creditsCard, order, 4)
			addHomeLabel(creditsCard, order + 1, member.Title, Enum.Font.GothamBold, entrySize, NebulaUI.Theme.Text)
			addHomeLabel(creditsCard, order + 2, member.Desc, Enum.Font.Gotham, bodySize, NebulaUI.Theme.MutedText)
			order = order + 3
		end

		-- Sincronizar la altura del contenedor con el contenido
		if isMobile then
			local function syncHeight()
				container.Size = UDim2.new(0.95, 0, 0, leftLayout.AbsoluteContentSize.Y)
			end
			leftLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncHeight)
			syncHeight()
		else
			creditsCard.AutomaticSize = Enum.AutomaticSize.None
			creditsCard.Position = UDim2.new(0.63, 0, 0, 0)
			creditsCard.Size = UDim2.new(0.37, 0, 0, 0)

			local creditsLayout = creditsCard:FindFirstChildOfClass("UIListLayout")
			local function syncHeights()
				local leftHeight = leftLayout.AbsoluteContentSize.Y
				local creditsHeight = creditsLayout.AbsoluteContentSize.Y + 22
				local total = math.max(leftHeight, creditsHeight)
				creditsCard.Size = UDim2.new(0.37, 0, 0, total)
				container.Size = UDim2.new(0.95, 0, 0, total)
			end
			leftLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncHeights)
			creditsLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncHeights)
			syncHeights()
		end
	end

	local translations = {
		EN = {
			HomeTab = "Home",

			HomeAboutSection = "About",
			HomeAboutTitle = "Touchline Reach v1.3.0",
			HomeAboutDesc = "Analysis and debugging tool for Touchline. It lets you visualize and adjust the ball interaction hitbox in real-time, tune mobility during actions, and customize the panel to your liking. Use the sidebar tabs to explore each module.",

			HomeChangelogSection = "Changelog",
			HomeChangelog = {
				{ Title = "v1.3.0 — Jul 2026", Desc = "New Home tab with About, Changelog and Credits." },
				{ Title = "v1.2.0 — Jun 2026", Desc = "Native Touch module hook and improved Tackle/Dive detection." },
				{ Title = "v1.1.0 — May 2026", Desc = "Speed system with slide mover and toast notifications." },
				{ Title = "v1.0.0 — Apr 2026", Desc = "Initial release: reach slider with real-time debug hitbox." },
			},

			HomeCreditsSection = "Credits",
			HomeCredits = {
				{ Title = "Crosslide", Desc = "Lead Developer" },
				{ Title = "NebulaUI", Desc = "Interface library powering this panel" },
				{ Title = "Discord Community", Desc = "Testing, feedback and support" },
			},

			ReachTab = "Reach",
			SpeedTab = "Speed",
			ConfigTab = "Configuration",
			CommTab = "Community",
			
			ReachTitle = "Interaction Range",
			ReachDesc = "Allows adjusting and analyzing the hitbox interaction zone of the character with the ball. Modifying the reach generates a translucent debug box in real-time.",
			ReachParam = "Reach Parameters",
			ReachCalculatedHeight = "Calculated Height: %.1f",
			ReachStudsSlider = "Reach (Studs)",
			
			SpeedTitle = "Debug Mobility",
			SpeedDesc = "Adjusts the character's simulated walk speed. Useful to analyze and debug physical behavior during Tackle or Dive actions.",
			SpeedParam = "Speed Settings",
			SpeedWalkSpeedSlider = "Walk Speed",
			
			ConfigTitle = "System Options",
			ConfigDesc = "Configures interface data persistence (auto-save to config.json) and customizes the panel's visual style in real-time.",
			ConfigParam = "Configuration Settings",
			ConfigAutoSave = "Auto-Save Configuration",
			ConfigAccentColor = "Accent Color",
			ConfigTheme = "Panel Theme",
			ConfigLang = "Language / Idioma",
			ConfigLockToggle = "Pin Nebula Button",
			ConfigSaveBtn = "Save Configuration",
			ConfigSaveDesc = "Manually saves the current settings to the JSON file.",
			ConfigSaveNotification = "Settings saved manually!",
			
			CommTitle = "Official Community",
			CommDesc = "Join our official channel to get the latest updates, share your feedback, or collaborate with other developers.",
			CommParam = "External Links",
			CommDiscordBtn = "Join Discord",
			CommDiscordDesc = "Copies the Discord invite link to your clipboard.",
			CommDiscordNotification = "Discord link copied to clipboard!",
			
			NotificationTitle = "Configuration"
		},
		ES = {
			HomeTab = "Inicio",

			HomeAboutSection = "Acerca de",
			HomeAboutTitle = "Touchline Reach v1.3.0",
			HomeAboutDesc = "Herramienta de análisis y depuración para Touchline. Permite visualizar y ajustar la hitbox de interacción con el balón en tiempo real, afinar la movilidad durante las acciones y personalizar el panel a tu gusto. Usá las pestañas de la barra lateral para explorar cada módulo.",

			HomeChangelogSection = "Changelog",
			HomeChangelog = {
				{ Title = "v1.3.0 — Jul 2026", Desc = "Nueva pestaña Inicio con Acerca de, Changelog y Créditos." },
				{ Title = "v1.2.0 — Jun 2026", Desc = "Hook nativo del módulo Touch y mejor detección de Tackle/Dive." },
				{ Title = "v1.1.0 — May 2026", Desc = "Sistema de velocidad con slide mover y notificaciones toast." },
				{ Title = "v1.0.0 — Abr 2026", Desc = "Lanzamiento inicial: slider de alcance con hitbox de depuración en tiempo real." },
			},

			HomeCreditsSection = "Créditos",
			HomeCredits = {
				{ Title = "Crosslide", Desc = "Desarrollador Principal" },
				{ Title = "NebulaUI", Desc = "Librería de interfaz que impulsa este panel" },
				{ Title = "Comunidad de Discord", Desc = "Testeo, sugerencias y soporte" },
			},

			ReachTab = "Rango",
			SpeedTab = "Velocidad",
			ConfigTab = "Configuración",
			CommTab = "Comunidad",
			
			ReachTitle = "Rango de Interacción",
			ReachDesc = "Permite ajustar y analizar la zona de interacción de la hitbox del personaje con el balón. Al modificar el alcance, se genera un cubo translúcido de depuración en tiempo real.",
			ReachParam = "Parámetros del Reach",
			ReachCalculatedHeight = "Altura calculada: %.1f",
			ReachStudsSlider = "Alcance (Studs)",
			
			SpeedTitle = "Movilidad de Depuración",
			SpeedDesc = "Ajusta la velocidad de caminata simulada del personaje. Sirve para analizar y depurar el comportamiento físico durante las acciones de Tackle o Dive.",
			SpeedParam = "Ajustes de Velocidad",
			SpeedWalkSpeedSlider = "Velocidad de Caminado",
			
			ConfigTitle = "Opciones del Sistema",
			ConfigDesc = "Configura la persistencia de datos de la interfaz (autoguardado en config.json) y personaliza el estilo visual del panel en tiempo real.",
			ConfigParam = "Ajustes de Configuración",
			ConfigAutoSave = "Autoguardado de Configuración",
			ConfigAccentColor = "Color de Acento",
			ConfigTheme = "Tema del Panel",
			ConfigLang = "Idioma / Language",
			ConfigLockToggle = "Fijar Botón de Nebula",
			ConfigSaveBtn = "Guardar Configuración",
			ConfigSaveDesc = "Guarda manualmente los valores actuales en el archivo JSON.",
			ConfigSaveNotification = "¡Configuración guardada manualmente!",
			
			CommTitle = "Comunidad Oficial",
			CommDesc = "Únete a nuestro canal para enterarte de las últimas actualizaciones, compartir tus sugerencias o colaborar con otros desarrolladores.",
			CommParam = "Enlaces Externos",
			CommDiscordBtn = "Unirse a Discord",
			CommDiscordDesc = "Copia el enlace de invitación de Discord al portapapeles.",
			CommDiscordNotification = "¡Enlace de Discord copiado al portapapeles!",
			
			NotificationTitle = "Configuración"
		}
	}

	local Window = nil

	-- Aplica el color de acento a la librería y también a los labels custom del Inicio
	local function applyAccentTheme(color)
		if not Window then return end
		Window:UpdateTheme(color)
		for _, label in ipairs(homeAccentLabels) do
			if label and label.Parent then
				label.TextColor3 = color
			end
		end
	end

	local function rebuildUI()
		if Window then
			Window:Destroy()
			Window = nil
		end

		NebulaUI:DestroyAll()
		
		Window = NebulaUI.CreateWindow({
			Title = "Touchline Reach",
			SubTitle = "Hitbox & Mobility Suite",
			ConfigSaving = {
				Enabled = true,
				Folder = "TouchlineReach",
				FileName = "config"
			}
		})
		
		-- Sincronizar variables locales de configuración guardadas
		if Window.Flags["ReachStuds"] then
			reachStuds = Window.Flags["ReachStuds"]
			heightStuds = HEIGHT_MIN_STUDS + (reachStuds - REACH_MIN_STUDS) * ((HEIGHT_MAX_STUDS - HEIGHT_MIN_STUDS) / (REACH_MAX_STUDS - REACH_MIN_STUDS))
		end
		if Window.Flags["WalkSpeed"] then
			customSpeed = Window.Flags["WalkSpeed"]
			speedEnabled = (customSpeed > 16)
		end
		-- Reaplicar tema y acento guardados (el dropdown y el picker no disparan
		-- su callback al construirse, así que se aplica explícitamente acá)
		local savedPreset = Window.Flags["ThemePreset"]
		local savedAccent = Window.Flags["AccentColor"]
		if savedPreset or savedAccent then
			task.spawn(function()
				task.wait(0.1)
				if savedPreset then
					Window:ApplyPreset(savedPreset)
				end
				if savedAccent then
					applyAccentTheme(savedAccent)
				end
			end)
		end
		
		local lang = "EN"
		if Window.Flags["LanguageSelector"] == "Español" then
			lang = "ES"
		end
		local t = translations[lang]
		
		local TabHome = Window:AddTab(t.HomeTab)
		local TabReach = Window:AddTab(t.ReachTab)
		local TabSpeed = Window:AddTab(t.SpeedTab)
		local TabConfig = Window:AddTab(t.ConfigTab)
		local TabComm = Window:AddTab(t.CommTab)

		-- Pestaña 0: Inicio (contenedor único con About, Changelog y Créditos)
		buildHomeTab(TabHome, t, Window.IsMobile)

		-- Pestaña 1: Reach
		TabReach:AddSeparator(t.ReachParam)
		TabReach:AddParagraph(t.ReachTitle, t.ReachDesc)
		local heightLabel = TabReach:AddLabel(string.format(t.ReachCalculatedHeight, heightStuds))
		
		TabReach:AddSlider(t.ReachStudsSlider, {
			Min = REACH_MIN_STUDS,
			Max = REACH_MAX_STUDS,
			Default = reachStuds,
			Rounding = 0,
			Flag = "ReachStuds",
			Callback = function(val)
				reachStuds = val
				publishReach()
				heightLabel.Set(string.format(t.ReachCalculatedHeight, heightStuds))
			end
		})
		
		-- Pestaña 2: Velocidad
		TabSpeed:AddSeparator(t.SpeedParam)
		TabSpeed:AddParagraph(t.SpeedTitle, t.SpeedDesc)
		TabSpeed:AddSlider(t.SpeedWalkSpeedSlider, {
			Min = 16,
			Max = 43,
			Default = customSpeed,
			Rounding = 0,
			Flag = "WalkSpeed",
			Callback = function(val)
				customSpeed = val
				speedEnabled = (val > 16)
				local humanoid = getHumanoid()
				if humanoid then
					humanoid.WalkSpeed = val
				end
			end
		})
		
		-- Pestaña: Configuración
		TabConfig:AddSeparator(t.ConfigParam)
		TabConfig:AddParagraph(t.ConfigTitle, t.ConfigDesc)
		TabConfig:AddToggle(t.ConfigAutoSave, {
			Default = true,
			Flag = "AutoSaveEnabled",
			Callback = function(state)
				Window.ConfigSaving.Enabled = state
			end
		})
		
		local accentPicker = TabConfig:AddColorPicker(t.ConfigAccentColor, {
			Default = NebulaUI.Theme.Accent,
			Flag = "AccentColor",
			Callback = function(color)
				applyAccentTheme(color)
			end
		})

		TabConfig:AddDropdown(t.ConfigTheme, {
			Items = {"Nebula", "Midnight", "Carbon", "Abyss"},
			Default = "Nebula",
			Flag = "ThemePreset",
			Callback = function(presetName)
				Window:ApplyPreset(presetName)
				-- Cargar el acento recomendado del preset: SetValue actualiza
				-- el preview del picker, el flag guardado y toda la UI
				local preset = NebulaUI.Presets and NebulaUI.Presets[presetName]
				if preset and preset.Accent then
					accentPicker.SetValue(preset.Accent)
				end
			end
		})

		TabConfig:AddDropdown(t.ConfigLang, {
			Items = {"English", "Español"},
			Default = lang == "EN" and "English" or "Español",
			Flag = "LanguageSelector",
			Callback = function(selected)
				local newLang = selected == "English" and "EN" or "ES"
				if newLang ~= lang then
					Window:SaveConfig()
					task.spawn(rebuildUI)
				end
			end
		})

		TabConfig:AddToggle(t.ConfigLockToggle, {
			Default = false,
			Flag = "LockNebulaToggle",
			Callback = function(state)
				Window:SetToggleLocked(state)
			end
		})
		-- AddToggle no dispara el callback al construirse: aplicar el valor guardado
		Window:SetToggleLocked(Window.Flags["LockNebulaToggle"] == true)

		TabConfig:AddButton(t.ConfigSaveBtn, {
			Description = t.ConfigSaveDesc,
			Callback = function()
				Window:SaveConfig()
				showNotification(t.NotificationTitle, t.ConfigSaveNotification)
			end
		})
		
		-- Pestaña 3: Comunidad
		TabComm:AddSeparator(t.CommParam)
		TabComm:AddParagraph(t.CommTitle, t.CommDesc)
		TabComm:AddButton(t.CommDiscordBtn, {
			Description = t.CommDiscordDesc,
			Callback = function()
				local inviteUrl = "https://discord.gg/k3qDHQt6A5"
				if setclipboard then
					setclipboard(inviteUrl)
				elseif toclipboard then
					toclipboard(inviteUrl)
				end
				showNotification(t.NotificationTitle, t.CommDiscordNotification)
			end
		})
	end

	rebuildUI()


	local function keyMatches(input, binding)
		if not binding then
			return false
		end

		if typeof(binding) == "EnumItem" then
			return input.KeyCode == binding
		end

		local ok, keyCode = pcall(function()
			return Enum.KeyCode[binding]
		end)

		return ok and input.KeyCode == keyCode
	end

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if nativeHookApplied then return end
		if gameProcessed or not isGameActive() then
			return
		end

		if keyMatches(input, options.Keybinds.Keyboard.Tackle) or keyMatches(input, options.Keybinds.Gamepad.Tackle) then
			rememberAction(getTackleAction())
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if nativeHookApplied then return end
		if not isGameActive() then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or keyMatches(input, options.Keybinds.Gamepad.Charge) then
			rememberAction(getChargeAction())
		end
	end))

	local gameGui = playerGui:FindFirstChild("Main") and playerGui.Main:FindFirstChild("Game")
	local mobile = gameGui and gameGui:FindFirstChild("Mobile")

	if mobile then
		if mobile:FindFirstChild("Charge") then
			table.insert(connections, mobile.Charge.MouseLeave:Connect(function()
				if nativeHookApplied then return end
				if isGameActive() then
					rememberAction(getChargeAction())
				end
			end))
		end

		if mobile:FindFirstChild("Tackle") then
			table.insert(connections, mobile.Tackle.MouseEnter:Connect(function()
				if nativeHookApplied then return end
				if isGameActive() then
					rememberAction(getTackleAction())
				end
			end))
		end
	end

	table.insert(connections, RunService.Heartbeat:Connect(function()
		-- Limpieza garantizada del estado de acción, independiente del hook nativo
		if activeScanAction and tick() > activeScanUntil then
			activeScanAction = nil
		end

		local root = getRoot()
		local humanoid = getHumanoid()

		if speedEnabled then
			if activeScanAction == "Tackle" or activeScanAction == "Dive" then
				if root and humanoid then
					local mover = root:FindFirstChild("TouchlineSlideMover")
					if not mover then
						mover = Instance.new("BodyVelocity")
						mover.Name = "TouchlineSlideMover"
						mover.MaxForce = Vector3.new(800000, 0, 800000)
						mover.Parent = root
					end
					local moveDir = humanoid.MoveDirection
					if moveDir.Magnitude < 0.1 then
						moveDir = root.CFrame.LookVector
					end
					local flatDirection = Vector3.new(moveDir.X, 0, moveDir.Z).Unit
					mover.Velocity = flatDirection * customSpeed
				end
			else
				if root then
					local mover = root:FindFirstChild("TouchlineSlideMover")
					if mover then
						mover:Destroy()
					end
				end
				if humanoid and humanoid.WalkSpeed ~= customSpeed then
					humanoid.WalkSpeed = customSpeed
				end
			end
		else
			if root then
				local mover = root:FindFirstChild("TouchlineSlideMover")
				if mover then
					mover:Destroy()
				end
			end
		end

		if nativeHookApplied then
			clearReachDebug()
		else
			if activeScanAction and tick() <= activeScanUntil then
				scanReach(activeScanOffset)
			else
				clearReachDebug()
			end
		end
	end))

	publishReach()

	-- Hookear el módulo Touch nativo usando debug.setupvalue si está disponible
	local function applyNativeHook()
		local ok, TouchModule = pcall(function()
			return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Touch"))
		end)
		
		if ok and TouchModule and TouchModule.Detect then
			hookedTouchModule = TouchModule
			local originalDetect = TouchModule.Detect
			originalDetectRef = originalDetect
			TouchModule.Detect = function(duration)
				if debug and debug.setupvalue then
					-- Upvalue 4 en Detect de touchline.lua corresponde a v_u_16 (el tamaño de la hitbox)
					local customSize = getReachSize()
					pcall(function()
						debug.setupvalue(originalDetect, 4, customSize)
					end)
				end
				return originalDetect(duration)
			end
			
			-- Hook Tackle/Dive para detectar el movimiento de forma infalible
			if TouchModule.Tackle then
				local originalTackle = TouchModule.Tackle
				originalTackleRef = originalTackle
				TouchModule.Tackle = function(...)
					local values = playerGui:FindFirstChild("Main") and playerGui.Main:FindFirstChild("Values")
					local action = "Tackle"
					if values and values:FindFirstChild("Goalie") and values.Goalie.Value == true and values:FindFirstChild("Diving") and values.Diving.Value == true then
						action = "Dive"
					end
					rememberAction(action)
					return originalTackle(...)
				end
			end

			nativeHookApplied = true
			print("[Touchline] Módulo Touch hookeado exitosamente.")
		else
			warn("[Touchline] No se pudo cargar o hookear el módulo Touch original. Se utilizará escaneo alternativo.")
		end
	end

	task.spawn(applyNativeHook)

	-- ====================================================================
	-- Registrar la descarga de ESTA instancia: la próxima ejecución del
	-- script la invoca antes de construir nada (ver bloque SINGLETON arriba)
	-- ====================================================================
	ENV.TouchlineReachUnload = function()
		for _, conn in ipairs(connections) do
			pcall(function() conn:Disconnect() end)
		end
		pcall(clearReachDebug)
		pcall(function()
			local root = getRoot()
			local mover = root and root:FindFirstChild("TouchlineSlideMover")
			if mover then
				mover:Destroy()
			end
		end)
		-- Restaurar los hooks del módulo Touch nativo
		if hookedTouchModule then
			if originalDetectRef then
				hookedTouchModule.Detect = originalDetectRef
			end
			if originalTackleRef then
				hookedTouchModule.Tackle = originalTackleRef
			end
			hookedTouchModule = nil
		end
		pcall(function()
			if Window then
				Window:Destroy()
			end
		end)
		pcall(function() NebulaUI:DestroyAll() end)
		local screen = playerGui:FindFirstChild("TouchlineReachDebugUI")
		if screen then
			screen:Destroy()
		end
	end

