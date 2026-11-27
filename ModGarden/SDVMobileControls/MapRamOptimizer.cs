using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using Microsoft.Xna.Framework.Content;
using Microsoft.Xna.Framework.Graphics;
using StardewModdingAPI;
using StardewValley;
using xTile;
using xTile.Tiles;

namespace SDVMobileControls
{
    /// <summary>
    /// Lossless SMAPI / Content Patcher Map Tilesheet RAM Optimizer for iOS.
    ///
    /// Why this saves 100-200+ MB with Recolor &amp; Expansion mods (0% quality loss, 0% audio impact):
    /// 1. Under SMAPI 4.x, GameContentManager &amp; ModContentManager store cached Texture2Ds in
    ///    BaseContentManager.Cache (ContentCache.Cache) + BaseDisposableReferences — NOT MonoGame's
    ///    ContentManager.loadedAssets. So legacy pruners never evicted SMAPI-cached tilesheets.
    /// 2. Recolor &amp; Expansion mods patch dozens of huge RGBA32 Maps/* tilesheets (8-16 MB each)
    ///    and Content Patcher packs can retain Texture2Ds in their ModContentManager.Cache.
    /// 3. On warp / day start / high-RAM GC, this optimizer safely evicts &amp; GPU-disposes ONLY
    ///    off-screen Maps/* tilesheets (keeping the current map + small LRU of recent maps) and
    ///    unreferenced textures inside pure Pathoschild.ContentPatcher content packs, while strictly
    ///    protecting all Audio, UI, Sprites, Buildings, TerrainFeatures, and C# mod textures.
    /// </summary>
    internal sealed class MapRamOptimizer
    {
        private sealed class ReferenceComparer : IEqualityComparer<Texture2D>
        {
            public static readonly ReferenceComparer Instance = new ReferenceComparer();
            public bool Equals(Texture2D x, Texture2D y) => ReferenceEquals(x, y);
            public int GetHashCode(Texture2D obj) => obj == null ? 0 : System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(obj);
        }

        private readonly IModHelper _helper;
        private readonly IMonitor _monitor;
        private readonly string _pruneFlagPath;
        private readonly string _gcFlagPath;

        // Track pure Pathoschild.ContentPatcher content packs (zero C# code -> safe to prune dead copies)
        private readonly HashSet<string> _cpPackNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly List<string> _cpPackDirs = new List<string>();
        private bool _cpPacksScanned;

        // Track every TileSheet.ImageSource ever observed + LRU warp sequence
        private readonly HashSet<string> _knownTileSheetKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, long> _lastUsedSeq = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        private long _warpSeq;
        private int _flagPollCounter;
        private long _lastWarpPruneMs;

        // Cached reflection handles (initialized lazily on first prune)
        private bool _reflReady;
        private FieldInfo _fCoordinator;
        private FieldInfo _fCacheObj;
        private FieldInfo _fCacheDict;
        private FieldInfo _fBaseDisposables;
        private FieldInfo _fContentManagers;
        private FieldInfo _fVanillaContentMgr;
        private FieldInfo _fModName;
        private PropertyInfo _pFullRootDir;
        private FieldInfo _fMgLoadedAssets;
        private FieldInfo _fMgDisposableAssets;
        private FieldInfo _fTileSheetTextures;
        private FieldInfo _fNpcPortrait;
        private FieldInfo[] _game1StaticTexFields;

        public MapRamOptimizer(IModHelper helper, IMonitor monitor)
        {
            _helper = helper;
            _monitor = monitor;
            string docs = Environment.GetFolderPath(Environment.SpecialFolder.Personal);
            string gardenDir = Path.Combine(docs, ".garden");
            try { Directory.CreateDirectory(gardenDir); } catch { }
            _pruneFlagPath = Path.Combine(gardenDir, "sdv_prune_now.flag");
            _gcFlagPath = Path.Combine(gardenDir, "sdv_gc_now.flag");
        }

        public void OnGameLaunched()
        {
            ScanContentPatcherPacks();
        }

        public void OnSaveLoaded()
        {
            ScanContentPatcherPacks();
            RecordCurrentMapTileSheets();
            EnsureCriticalTexturesIntact(Game1.currentLocation);
        }

        public void OnWarped(GameLocation newLocation)
        {
            if (!Context.IsWorldReady || newLocation == null)
                return;
            RecordLocationTileSheets(newLocation);
            EnsureCriticalTexturesIntact(newLocation);
            // Cooldown prevents hitching when stepping rapidly between FarmHouse/Coop/Barn/Shops
            long nowMs = Environment.TickCount64;
            if (nowMs - _lastWarpPruneMs < 12000L)
                return;
            _lastWarpPruneMs = nowMs;
            // Keep up to 2 most recently visited off-screen tilesheets so stepping in/out stays instant while evicting older maps!
            RunPrune(keepRecentOffscreen: 2, runGc: false, blockingGc: false, reason: "Warp:" + (newLocation.NameOrUniqueName ?? "?"));
        }

        public void OnDayStarted()
        {
            if (!Context.IsWorldReady)
                return;
            RecordCurrentMapTileSheets();
            EnsureCriticalTexturesIntact(Game1.currentLocation);
            // NEVER run blocking compacting Gen2 GC right as the player wakes up on bed — prevents wake-up freeze!
            if (_knownTileSheetKeys.Count <= 4)
                return;
            RunPrune(keepRecentOffscreen: 1, runGc: false, blockingGc: false, reason: "DayStarted");
        }

        public void OnReturnedToTitle()
        {
            _knownTileSheetKeys.Clear();
            _lastUsedSeq.Clear();
            _warpSeq = 0;
            _lastWarpPruneMs = 0;
        }

        /// <summary>
        /// Verifies core world/fishing/water textures (bobbers, cursors, animations, and active map tilesheets)
        /// are never disposed/corrupted on iOS OpenGL ES, auto-healing any stale GPU texture handle cleanly.
        /// </summary>
        public void EnsureCriticalTexturesIntact(GameLocation loc)
        {
            try
            {
                if (Game1.content != null)
                {
                    if (Game1.bobbersTexture == null || Game1.bobbersTexture.IsDisposed)
                        Game1.bobbersTexture = Game1.content.Load<Texture2D>("TileSheets\\bobbers");
                    if (Game1.mouseCursors == null || Game1.mouseCursors.IsDisposed)
                        Game1.mouseCursors = Game1.content.Load<Texture2D>("LooseSprites/Cursors");
                    if (Game1.animations == null || Game1.animations.IsDisposed)
                        Game1.animations = Game1.content.Load<Texture2D>("TileSheets\\animations");
                }
                if (loc?.Map != null && EnsureReflection(Game1.content) && _fTileSheetTextures != null && Game1.mapDisplayDevice != null)
                {
                    var tsDict = _fTileSheetTextures.GetValue(Game1.mapDisplayDevice) as Dictionary<TileSheet, Texture2D>;
                    if (tsDict != null && loc.Map.TileSheets != null)
                    {
                        for (int i = 0; i < loc.Map.TileSheets.Count; i++)
                        {
                            TileSheet ts = loc.Map.TileSheets[i];
                            if (ts != null && tsDict.TryGetValue(ts, out Texture2D tex) && (tex == null || tex.IsDisposed))
                            {
                                tsDict.Remove(ts);
                            }
                        }
                    }
                }
            }
            catch { }
        }

        public void PollManualPruneFlag()
        {
            if (!Context.IsWorldReady)
                return;
            if (++_flagPollCounter < 30)
                return;
            _flagPollCounter = 0;
            try
            {
                if (!File.Exists(_pruneFlagPath))
                    return;
                string mode = "";
                try { mode = File.ReadAllText(_pruneFlagPath)?.Trim() ?? ""; } catch { }
                try { File.Delete(_pruneFlagPath); } catch { }
                // Consume companion sdv_gc_now.flag if also present so TouchVirtualPad.CheckManualGcFlag never runs a duplicate blocking Gen2 GC!
                try { if (File.Exists(_gcFlagPath)) File.Delete(_gcFlagPath); } catch { }
                bool critical = string.Equals(mode, "CRIT", StringComparison.OrdinalIgnoreCase);
                RunPrune(keepRecentOffscreen: 0, runGc: true, blockingGc: critical, reason: critical ? "AutoCritGC" : "ManualGC");
            }
            catch { }
        }

        public void RunAggressivePrune(string reason)
        {
            if (!Context.IsWorldReady)
                return;
            bool isCrit = reason != null && reason.IndexOf("90", StringComparison.Ordinal) >= 0;
            RunPrune(keepRecentOffscreen: 0, runGc: true, blockingGc: isCrit, reason: reason ?? "HighRAM");
        }

        /// <summary>
        /// Safely refreshes stale or Content Patcher-invalidated NPC portraits without relying on
        /// MonoGame iOS Texture2D.CopyFromTexture() (which uses OpenGL ES FBO + glReadPixels and
        /// silently swallows failures, leaving early-loaded villagers stuck on vanilla portraits
        /// while lazy-loaded villagers show Seasonal Anime Portraits).
        /// </summary>
        public int RefreshInvalidatedPortraits(HashSet<string> invalidatedNormKeys, bool reloadAll, string reason)
        {
            if (!Context.IsWorldReady || Game1.content == null)
                return 0;
            if (!EnsureReflection(Game1.content) || _fNpcPortrait == null)
                return 0;

            int unlinkedCacheKeys = 0;
            int refreshedNpcs = 0;
            int eagerReloaded = 0;
            try
            {
                object coordinator = _fCoordinator.GetValue(Game1.content);
                var mgrListObj = coordinator != null ? (_fContentManagers.GetValue(coordinator) as IEnumerable) : null;

                // 1. Unlink ONLY stale/invalidated Portraits/* entries from GameContentManagers (never Dispose!)
                //    so the next Game1.content.Load<Texture2D>() creates a fresh Texture2D straight from Content Patcher.
                if (mgrListObj != null)
                {
                    var gameManagers = new List<object>(8);
                    foreach (object m in mgrListObj)
                    {
                        if (m != null && m.GetType().Name.IndexOf("GameContentManager", StringComparison.Ordinal) >= 0)
                            gameManagers.Add(m);
                    }

                    var unlinkedTex = new HashSet<Texture2D>(ReferenceComparer.Instance);
                    foreach (object gm in gameManagers)
                    {
                        var dict = GetCacheDict(gm);
                        if (dict == null || dict.Count == 0) continue;
                        List<string> rmKeys = null;
                        foreach (var kv in dict)
                        {
                            if (!(kv.Value is Texture2D tex))
                                continue;
                            string norm = NormalizeAssetKey(kv.Key);
                            if (!norm.StartsWith("portraits/", StringComparison.OrdinalIgnoreCase))
                                continue;
                            if (reloadAll || (invalidatedNormKeys != null && invalidatedNormKeys.Contains(norm)))
                            {
                                if (rmKeys == null) rmKeys = new List<string>(16);
                                rmKeys.Add(kv.Key);
                                unlinkedTex.Add(tex);
                            }
                        }
                        if (rmKeys != null)
                        {
                            for (int i = 0; i < rmKeys.Count; i++)
                            {
                                if (dict.TryGetValue(rmKeys[i], out object v) && v is Texture2D t)
                                    RemoveFromBaseDisposables(gm, t);
                                dict.Remove(rmKeys[i]);
                                unlinkedCacheKeys++;
                            }
                        }
                    }

                    if (unlinkedTex.Count > 0)
                        PurgeFromMonoGameContentManager(_fVanillaContentMgr?.GetValue(coordinator), unlinkedTex);
                }

                // 2. Refresh every NPC (top-level locations + all building interiors + active event actors)
                var currentLoc = Game1.currentLocation;
                void RefreshNpc(NPC ch, bool isLocalOrEvent)
                {
                    if (ch == null || ch.portraitOverridden ||
                        ch is StardewValley.Monsters.Monster ||
                        ch is StardewValley.Characters.Pet ||
                        ch is StardewValley.Characters.Horse)
                        return;

                    Texture2D curTex = _fNpcPortrait.GetValue(ch) as Texture2D;
                    bool shouldRefresh = reloadAll;
                    if (!shouldRefresh && invalidatedNormKeys != null && invalidatedNormKeys.Count > 0)
                    {
                        string curNorm = curTex != null ? NormalizeAssetKey(curTex.Name) : null;
                        if (!string.IsNullOrEmpty(curNorm) && invalidatedNormKeys.Contains(curNorm))
                            shouldRefresh = true;
                        else
                        {
                            string texName = null;
                            try { texName = ch.getTextureName(); } catch { }
                            string[] candidates = !string.IsNullOrEmpty(texName) && !string.Equals(texName, ch.Name, StringComparison.OrdinalIgnoreCase)
                                ? new[] { ch.Name, texName }
                                : new[] { ch.Name };
                            for (int ci = 0; ci < candidates.Length && !shouldRefresh; ci++)
                            {
                                string cand = candidates[ci];
                                if (string.IsNullOrEmpty(cand)) continue;
                                string baseKey = "portraits/" + cand.ToLowerInvariant();
                                if (invalidatedNormKeys.Contains(baseKey))
                                {
                                    shouldRefresh = true;
                                    break;
                                }
                                string prefix = baseKey + "_";
                                foreach (string ik in invalidatedNormKeys)
                                {
                                    if (ik.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                                    {
                                        shouldRefresh = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    if (!shouldRefresh)
                        return;

                    if (!ch.IsVillager && curTex == null)
                        return;

                    _fNpcPortrait.SetValue(ch, null);
                    try { ch.LastAppearanceId = null; } catch { }
                    refreshedNpcs++;

                    if (isLocalOrEvent || ReferenceEquals(ch.currentLocation, currentLoc))
                    {
                        try
                        {
                            ch.ChooseAppearance(null);
                            eagerReloaded++;
                        }
                        catch { }
                    }
                }

                Utility.ForEachCharacter(ch =>
                {
                    RefreshNpc(ch, isLocalOrEvent: false);
                    return true;
                });

                var evActors = Game1.CurrentEvent?.actors;
                if (evActors != null)
                {
                    for (int i = 0; i < evActors.Count; i++)
                        RefreshNpc(evActors[i], isLocalOrEvent: true);
                }

                if (refreshedNpcs > 0 || unlinkedCacheKeys > 0)
                {
                    _monitor?.Log($"[PortraitSync:{reason}] Refreshed {refreshedNpcs} NPCs ({eagerReloaded} local eager, {unlinkedCacheKeys} cached Portraits/* reset for fresh Content Patcher load).", LogLevel.Info);
                }
            }
            catch (Exception ex)
            {
                _monitor?.Log($"[PortraitSync:{reason}] Error: {ex.Message}", LogLevel.Trace);
            }
            return refreshedNpcs;
        }

        public static string NormalizePortraitKey(string raw) => NormalizeAssetKey(raw);

        /// <summary>
        /// Ensures villagers in a newly entered location refresh seasonal/anime Content Patcher portraits cleanly on warp
        /// (credit @Mudkip267 for OnWarped portrait refresh &amp; LastAppearanceId reset insight).
        /// </summary>
        public int RefreshLocationPortraits(GameLocation loc)
        {
            if (!Context.IsWorldReady || loc?.characters == null || Game1.content == null)
                return 0;
            if (!EnsureReflection(Game1.content) || _fNpcPortrait == null)
                return 0;

            int count = 0;
            try
            {
                for (int i = 0; i < loc.characters.Count; i++)
                {
                    NPC ch = loc.characters[i];
                    if (ch == null || ch.portraitOverridden || !ch.IsVillager ||
                        ch is StardewValley.Monsters.Monster ||
                        ch is StardewValley.Characters.Pet ||
                        ch is StardewValley.Characters.Horse)
                        continue;

                    Texture2D curTex = _fNpcPortrait.GetValue(ch) as Texture2D;
                    if (curTex == null || curTex.IsDisposed)
                    {
                        _fNpcPortrait.SetValue(ch, null);
                        try { ch.LastAppearanceId = null; } catch { }
                        try { ch.ChooseAppearance(null); } catch { }
                        count++;
                    }
                }
            }
            catch { }
            return count;
        }

        private static bool IsProtectedContentPack(string uid, string name)
        {
            string combined = ((uid ?? "") + " " + (name ?? "")).ToLowerInvariant();
            return combined.Contains("vietnam") ||
                   combined.Contains("viethoa") ||
                   combined.Contains("việt") ||
                   combined.Contains("translation") ||
                   combined.Contains("portrait") ||
                   combined.Contains("anime") ||
                   combined.Contains("seasonal") ||
                   combined.Contains("character") ||
                   combined.Contains("outfit") ||
                   combined.Contains("font");
        }

        private void ScanContentPatcherPacks()
        {
            if (_cpPacksScanned || _helper?.ModRegistry == null)
                return;
            _cpPacksScanned = true;
            try
            {
                foreach (IModInfo mod in _helper.ModRegistry.GetAll())
                {
                    if (mod == null || !mod.IsContentPack)
                        continue;
                    string packFor = mod.Manifest?.ContentPackFor?.UniqueID;
                    if (!string.Equals(packFor, "Pathoschild.ContentPatcher", StringComparison.OrdinalIgnoreCase))
                        continue;
                    if (IsProtectedContentPack(mod.Manifest?.UniqueID, mod.Manifest?.Name))
                        continue;
                    if (!string.IsNullOrEmpty(mod.Manifest.Name))
                        _cpPackNames.Add(mod.Manifest.Name);
                    // Also capture DirectoryPath via reflection on ModMetadata if available
                    try
                    {
                        PropertyInfo pDir = mod.GetType().GetProperty("DirectoryPath", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                        string dir = pDir?.GetValue(mod) as string;
                        if (!string.IsNullOrEmpty(dir))
                            _cpPackDirs.Add(NormalizeDir(dir));
                    }
                    catch { }
                }
                if (_cpPackNames.Count > 0)
                    _monitor?.Log($"[MapRamOptimizer] Ready (tracking {_cpPackNames.Count} Content Patcher packs).", LogLevel.Debug);
            }
            catch { }
        }

        private void RecordCurrentMapTileSheets()
        {
            if (Game1.currentLocation != null)
                RecordLocationTileSheets(Game1.currentLocation);
        }

        private void RecordLocationTileSheets(GameLocation loc)
        {
            _warpSeq++;
            Map map = loc?.Map;
            if (map?.TileSheets == null)
                return;
            for (int i = 0; i < map.TileSheets.Count; i++)
            {
                TileSheet ts = map.TileSheets[i];
                if (ts == null || string.IsNullOrEmpty(ts.ImageSource))
                    continue;
                string norm = NormalizeAssetKey(ts.ImageSource);
                if (string.IsNullOrEmpty(norm))
                    continue;
                _knownTileSheetKeys.Add(norm);
                _lastUsedSeq[norm] = _warpSeq;
                if (!norm.StartsWith("maps/", StringComparison.OrdinalIgnoreCase))
                {
                    string withMaps = "maps/" + norm;
                    _knownTileSheetKeys.Add(withMaps);
                    _lastUsedSeq[withMaps] = _warpSeq;
                }
            }
        }

        private bool EnsureReflection(object mainContent)
        {
            if (_reflReady)
                return _fCoordinator != null && _fCacheObj != null && _fCacheDict != null && _fContentManagers != null;

            _reflReady = true;
            const BindingFlags any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            const BindingFlags stat = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

            try
            {
                Type bcmType = FindBaseTypeNamed(mainContent?.GetType(), "BaseContentManager");
                if (bcmType != null)
                {
                    _fCoordinator = bcmType.GetField("Coordinator", any);
                    _fCacheObj = bcmType.GetField("Cache", any);
                    _fBaseDisposables = bcmType.GetField("BaseDisposableReferences", any);
                    _pFullRootDir = bcmType.GetProperty("FullRootDirectory", any);

                    if (_fCacheObj != null)
                        _fCacheDict = _fCacheObj.FieldType.GetField("Cache", any);
                    if (_fCoordinator != null)
                    {
                        _fContentManagers = _fCoordinator.FieldType.GetField("ContentManagers", any);
                        _fVanillaContentMgr = _fCoordinator.FieldType.GetField("VanillaContentManager", any);
                    }

                    Assembly smapiAsm = bcmType.Assembly;
                    Type mcmType = smapiAsm.GetType("StardewModdingAPI.Framework.ContentManagers.ModContentManager");
                    if (mcmType != null)
                        _fModName = mcmType.GetField("ModName", any);
                }

                _fMgLoadedAssets = typeof(ContentManager).GetField("loadedAssets", any);
                _fMgDisposableAssets = typeof(ContentManager).GetField("disposableAssets", any);

                Type xnaDispType = typeof(xTile.Display.XnaDisplayDevice);
                _fTileSheetTextures = xnaDispType.GetField("m_tileSheetTextures", any);
                _fNpcPortrait = typeof(NPC).GetField("portrait", any);

                var texFields = new List<FieldInfo>();
                foreach (FieldInfo fi in typeof(Game1).GetFields(stat))
                {
                    if (typeof(Texture2D).IsAssignableFrom(fi.FieldType))
                        texFields.Add(fi);
                }
                _game1StaticTexFields = texFields.ToArray();
            }
            catch (Exception ex)
            {
                _monitor?.Log($"[MapRamOptimizer] Reflection init skipped: {ex.Message}", LogLevel.Trace);
            }

            return _fCoordinator != null && _fCacheObj != null && _fCacheDict != null && _fContentManagers != null;
        }

        private void RunPrune(int keepRecentOffscreen, bool runGc, bool blockingGc, string reason)
        {
            // Never prune while actively saving, mid-event, or inside title/minigame
            if (Game1.content == null || Game1.currentLocation == null || Game1.eventUp || Game1.currentMinigame != null)
                return;

            if (!EnsureReflection(Game1.content))
                return;

            try
            {
                object coordinator = _fCoordinator.GetValue(Game1.content);
                if (coordinator == null)
                    return;

                var mgrListObj = _fContentManagers.GetValue(coordinator) as IEnumerable;
                if (mgrListObj == null)
                    return;

                // Snapshot content managers to avoid concurrent modification
                var allManagers = new List<object>(32);
                var gameManagers = new List<object>(8);
                var modManagers = new List<object>(24);

                foreach (object m in mgrListObj)
                {
                    if (m == null) continue;
                    allManagers.Add(m);
                    string tn = m.GetType().Name;
                    if (tn.IndexOf("GameContentManager", StringComparison.Ordinal) >= 0)
                        gameManagers.Add(m);
                    else if (tn.IndexOf("ModContentManager", StringComparison.Ordinal) >= 0)
                        modManagers.Add(m);
                }

                // 1. Collect currently active map tilesheet keys + protected Texture2D object references
                var activeKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var activeBasenames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var protectedTex = new HashSet<Texture2D>(ReferenceComparer.Instance);

                Map curMap = Game1.currentLocation.Map;
                if (curMap?.TileSheets != null)
                {
                    for (int i = 0; i < curMap.TileSheets.Count; i++)
                    {
                        TileSheet ts = curMap.TileSheets[i];
                        if (ts == null || string.IsNullOrEmpty(ts.ImageSource))
                            continue;
                        string norm = NormalizeAssetKey(ts.ImageSource);
                        if (string.IsNullOrEmpty(norm))
                            continue;
                        activeKeys.Add(norm);
                        if (!norm.StartsWith("maps/", StringComparison.OrdinalIgnoreCase))
                            activeKeys.Add("maps/" + norm);
                        string baseNm = GetBaseName(norm);
                        if (!string.IsNullOrEmpty(baseNm))
                            activeBasenames.Add(baseNm);
                    }
                }

                // Protect all static Game1 Texture2D fields + Vietnamese/SpriteFont textures (credit @Mudkip267)
                if (_game1StaticTexFields != null)
                {
                    for (int i = 0; i < _game1StaticTexFields.Length; i++)
                    {
                        try
                        {
                            if (_game1StaticTexFields[i].GetValue(null) is Texture2D gt)
                                protectedTex.Add(gt);
                        }
                        catch { }
                    }
                }
                try
                {
                    if (Game1.smallFont?.Texture != null) protectedTex.Add(Game1.smallFont.Texture);
                    if (Game1.dialogueFont?.Texture != null) protectedTex.Add(Game1.dialogueFont.Texture);
                }
                catch { }

                // Protect active map's Texture2Ds in Game1.mapDisplayDevice.m_tileSheetTextures
                Dictionary<TileSheet, Texture2D> tsDict = null;
                if (_fTileSheetTextures != null && Game1.mapDisplayDevice != null)
                {
                    try
                    {
                        tsDict = _fTileSheetTextures.GetValue(Game1.mapDisplayDevice) as Dictionary<TileSheet, Texture2D>;
                        if (tsDict != null)
                        {
                            foreach (var kv in tsDict)
                            {
                                if (kv.Key != null && kv.Value != null)
                                {
                                    // Record every tilesheet image source we ever encounter
                                    if (!string.IsNullOrEmpty(kv.Key.ImageSource))
                                    {
                                        string kn = NormalizeAssetKey(kv.Key.ImageSource);
                                        if (!string.IsNullOrEmpty(kn))
                                        {
                                            _knownTileSheetKeys.Add(kn);
                                            if (!kn.StartsWith("maps/", StringComparison.OrdinalIgnoreCase))
                                                _knownTileSheetKeys.Add("maps/" + kn);
                                        }
                                    }
                                    if (kv.Key.Map == curMap)
                                        protectedTex.Add(kv.Value);
                                }
                            }
                        }
                    }
                    catch { }
                }

                // Protect ALL villager/NPC portraits across every location, building interior, and active event.
                // Never evict Portraits/* during RAM pruning — all portraits combined are small (~6-8 MB),
                // and evicting them breaks Content Patcher Seasonal Anime Portrait propagation on iOS!
                bool prunePortraits = false;
                if (_fNpcPortrait != null)
                {
                    try
                    {
                        Utility.ForEachCharacter(ch =>
                        {
                            if (ch != null && _fNpcPortrait.GetValue(ch) is Texture2D pt && !pt.IsDisposed)
                                protectedTex.Add(pt);
                            return true;
                        });
                        var evActors = Game1.CurrentEvent?.actors;
                        if (evActors != null)
                        {
                            for (int i = 0; i < evActors.Count; i++)
                            {
                                NPC ch = evActors[i];
                                if (ch != null && _fNpcPortrait.GetValue(ch) is Texture2D pt && !pt.IsDisposed)
                                    protectedTex.Add(pt);
                            }
                        }
                    }
                    catch { }
                }

                // Protect non-evictable textures in ALL GameContentManagers (in case a texture is shared under a protected key)
                foreach (object gm in gameManagers)
                {
                    var dict = GetCacheDict(gm);
                    if (dict == null) continue;
                    foreach (var kv in dict)
                    {
                        if (kv.Value is Texture2D tex && !tex.IsDisposed)
                        {
                            string norm = NormalizeAssetKey(kv.Key);
                            if (!IsEvictableAssetKey(norm, activeKeys, activeBasenames, prunePortraits))
                                protectedTex.Add(tex);
                        }
                    }
                }

                // 2. Find candidate off-screen map tilesheets & off-screen villager portraits across all GameContentManagers
                var candidates = new List<(object mgr, string rawKey, string normKey, Texture2D tex, long seq)>();
                var candidateByTex = new HashSet<Texture2D>(ReferenceComparer.Instance);

                foreach (object gm in gameManagers)
                {
                    var dict = GetCacheDict(gm);
                    if (dict == null) continue;
                    foreach (var kv in dict)
                    {
                        if (!(kv.Value is Texture2D tex) || tex.IsDisposed)
                            continue;
                        if (protectedTex.Contains(tex))
                            continue;

                        string norm = NormalizeAssetKey(kv.Key);
                        if (!IsEvictableAssetKey(norm, activeKeys, activeBasenames, prunePortraits))
                            continue;

                        _lastUsedSeq.TryGetValue(norm, out long seq);
                        candidates.Add((gm, kv.Key, norm, tex, seq));
                        candidateByTex.Add(tex);
                    }
                }

                // Apply LRU retention: keep the N most recently visited off-screen tilesheet textures
                if (keepRecentOffscreen > 0 && candidateByTex.Count > keepRecentOffscreen)
                {
                    // Sort distinct candidate textures by newest _lastUsedSeq descending
                    var texOrder = new List<(Texture2D tex, long seq)>(candidateByTex.Count);
                    var seenSeq = new Dictionary<Texture2D, long>(ReferenceComparer.Instance);
                    for (int i = 0; i < candidates.Count; i++)
                    {
                        var c = candidates[i];
                        if (!seenSeq.TryGetValue(c.tex, out long prev) || c.seq > prev)
                            seenSeq[c.tex] = c.seq;
                    }
                    foreach (var kv in seenSeq)
                        texOrder.Add((kv.Key, kv.Value));
                    texOrder.Sort((a, b) => b.seq.CompareTo(a.seq));

                    for (int i = 0; i < keepRecentOffscreen && i < texOrder.Count; i++)
                        protectedTex.Add(texOrder[i].tex);
                }
                else if (keepRecentOffscreen > 0 && candidateByTex.Count <= keepRecentOffscreen)
                {
                    foreach (Texture2D t in candidateByTex)
                        protectedTex.Add(t);
                }

                // 3. Collect final set of off-screen map/portrait Texture2Ds to evict from SMAPI caches.
                //    CRITICAL iOS OpenGL ES + Shader Mod Safety (SDV-Radiance, DynamicReflections, etc.):
                //    Never call tex.Dispose() eagerly on shared GameContentManager textures because C# rendering
                //    mods cache Texture2D references loaded from Game1.content (e.g., ShadowRenderer._textureCache
                //    and _propCache). Eagerly deleting their GL texture leaves glTexture = -1, which OpenGL ES
                //    samples as solid opaque black (0,0,0,1) blocks!
                //    Instead: unlink them from all SMAPI/MonoGame/xTile caches so .NET GC collects unreferenced
                //    textures and MonoGame's GraphicsResource finalizer safely calls GraphicsDevice.DisposeTexture()
                //    ONLY once zero mods hold a reference. Pure Content Patcher (0% C# code) dead copies still
                //    dispose immediately for instant VRAM reclamation.
                var toUnlink = new HashSet<Texture2D>(ReferenceComparer.Instance);
                var toImmediateDispose = new HashSet<Texture2D>(ReferenceComparer.Instance);
                for (int i = 0; i < candidates.Count; i++)
                {
                    var c = candidates[i];
                    if (protectedTex.Contains(c.tex))
                        continue;
                    var dict = GetCacheDict(c.mgr);
                    dict?.Remove(c.rawKey);
                    RemoveFromBaseDisposables(c.mgr, c.tex);
                    toUnlink.Add(c.tex);
                }

                // 4. Clean ModContentManagers ONLY for textures already in `toUnlink` (off-screen evicted map tilesheets).
                //    CRITICAL iOS OpenGL ES Texture Integrity Fix: NEVER eagerly call tex.Dispose() on Content Patcher
                //    ModContentManager textures! Content Patcher retains source PNGs for EditImage/Load re-patching
                //    (Cursors, Beach, Bobbers, UI, Recolor); eager glDeleteTextures causes corrupted/black sprites!
                if (toUnlink.Count > 0)
                {
                    foreach (object mm in modManagers)
                    {
                        var dict = GetCacheDict(mm);
                        if (dict == null || dict.Count == 0) continue;

                        List<string> rmKeys = null;
                        foreach (var kv in dict)
                        {
                            if (kv.Value is Texture2D mtex && toUnlink.Contains(mtex))
                            {
                                if (rmKeys == null) rmKeys = new List<string>(4);
                                rmKeys.Add(kv.Key);
                            }
                        }

                        if (rmKeys != null)
                        {
                            for (int i = 0; i < rmKeys.Count; i++)
                            {
                                if (dict.TryGetValue(rmKeys[i], out object v) && v is Texture2D mt)
                                    RemoveFromBaseDisposables(mm, mt);
                                dict.Remove(rmKeys[i]);
                            }
                        }
                    }
                }

                // 5. Also ensure NO remaining entry in ANY GameContentManager, m_tileSheetTextures,
                //    NPC.portrait, or VanillaContentManager retains a texture we evicted!
                if (toUnlink.Count > 0)
                {
                    foreach (object gm in gameManagers)
                    {
                        var dict = GetCacheDict(gm);
                        if (dict == null) continue;
                        List<string> extraRm = null;
                        foreach (var kv in dict)
                        {
                            if (kv.Value is Texture2D gt && toUnlink.Contains(gt))
                            {
                                if (extraRm == null) extraRm = new List<string>(4);
                                extraRm.Add(kv.Key);
                            }
                        }
                        if (extraRm != null)
                        {
                            for (int i = 0; i < extraRm.Count; i++)
                                dict.Remove(extraRm[i]);
                        }
                        foreach (Texture2D dt in toUnlink)
                            RemoveFromBaseDisposables(gm, dt);
                    }

                    if (tsDict != null)
                    {
                        List<TileSheet> rmTs = null;
                        foreach (var kv in tsDict)
                        {
                            if (kv.Value != null && toUnlink.Contains(kv.Value))
                            {
                                if (rmTs == null) rmTs = new List<TileSheet>(8);
                                rmTs.Add(kv.Key);
                            }
                        }
                        if (rmTs != null)
                        {
                            for (int i = 0; i < rmTs.Count; i++)
                                tsDict.Remove(rmTs[i]);
                        }
                    }

                    // Null off-screen villager npc.portrait references so NPC.get_Portrait() reloads cleanly via ChooseAppearance!
                    if (_fNpcPortrait != null)
                    {
                        try
                        {
                            if (Game1.locations != null)
                            {
                                for (int l = 0; l < Game1.locations.Count; l++)
                                {
                                    var loc = Game1.locations[l];
                                    if (loc?.characters == null) continue;
                                    for (int c = 0; c < loc.characters.Count; c++)
                                    {
                                        NPC ch = loc.characters[c];
                                        if (ch != null && _fNpcPortrait.GetValue(ch) is Texture2D pt && toUnlink.Contains(pt))
                                        {
                                            if (ch.IsVillager && !ch.portraitOverridden)
                                                _fNpcPortrait.SetValue(ch, null);
                                            else
                                                toImmediateDispose.Remove(pt);
                                        }
                                    }
                                }
                            }
                        }
                        catch { }
                    }

                    // Clean VanillaContentManager.loadedAssets / disposableAssets if present
                    PurgeFromMonoGameContentManager(_fVanillaContentMgr?.GetValue(coordinator), toUnlink);

                    // 6. Immediately dispose ONLY pure Content Patcher dead copies (0% C# references);
                    //    shared GameContentManager textures are freed safely via GC finalizer ONLY when
                    //    no C# mod (e.g., SDV-Radiance / DynamicReflections) still references them!
                    long bytesImmediate = 0;
                    long bytesGcCandidate = 0;
                    int disposedCount = 0;
                    int unlinkedCount = 0;
                    foreach (Texture2D tex in toUnlink)
                    {
                        if (tex == null || tex.IsDisposed)
                            continue;
                        long texBytes = (long)tex.Width * tex.Height * 4L;
                        if (toImmediateDispose.Contains(tex))
                        {
                            try
                            {
                                tex.Dispose();
                                bytesImmediate += texBytes;
                                disposedCount++;
                            }
                            catch { }
                        }
                        else
                        {
                            bytesGcCandidate += texBytes;
                            unlinkedCount++;
                        }
                    }

                    if (disposedCount > 0 || unlinkedCount > 0)
                    {
                        double mbImm = bytesImmediate / (1024.0 * 1024.0);
                        double mbGc = bytesGcCandidate / (1024.0 * 1024.0);
                        _monitor?.Log($"[MapRamOptimizer] ({reason}) Freed {disposedCount} CP textures ({mbImm:F1} MB) + unlinked {unlinkedCount} off-screen textures ({mbGc:F1} MB GC-safe).", LogLevel.Info);

                        if (runGc && blockingGc)
                        {
                            try
                            {
                                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
                            }
                            catch { }
                        }
                        else if (runGc || (bytesImmediate + bytesGcCandidate) >= 24L * 1024L * 1024L)
                        {
                            try
                            {
                                GC.Collect(1, GCCollectionMode.Optimized, blocking: false);
                            }
                            catch { }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _monitor?.Log($"[MapRamOptimizer] Prune error ({reason}): {ex.Message}", LogLevel.Trace);
            }
        }

        private Dictionary<string, object> GetCacheDict(object contentMgr)
        {
            if (contentMgr == null || _fCacheObj == null || _fCacheDict == null)
                return null;
            try
            {
                object cacheObj = _fCacheObj.GetValue(contentMgr);
                if (cacheObj == null) return null;
                return _fCacheDict.GetValue(cacheObj) as Dictionary<string, object>;
            }
            catch { return null; }
        }

        private void RemoveFromBaseDisposables(object contentMgr, Texture2D tex)
        {
            if (contentMgr == null || tex == null || _fBaseDisposables == null)
                return;
            try
            {
                var list = _fBaseDisposables.GetValue(contentMgr) as List<IDisposable>;
                if (list != null)
                {
                    for (int i = list.Count - 1; i >= 0; i--)
                    {
                        if (ReferenceEquals(list[i], tex))
                            list.RemoveAt(i);
                    }
                }
            }
            catch { }
        }

        private void PurgeFromMonoGameContentManager(object cmObj, HashSet<Texture2D> toDispose)
        {
            if (cmObj == null || _fMgLoadedAssets == null)
                return;
            try
            {
                var loaded = _fMgLoadedAssets.GetValue(cmObj) as IDictionary;
                if (loaded != null)
                {
                    List<object> rm = null;
                    foreach (DictionaryEntry de in loaded)
                    {
                        if (de.Value is Texture2D t && toDispose.Contains(t))
                        {
                            if (rm == null) rm = new List<object>(4);
                            rm.Add(de.Key);
                        }
                    }
                    if (rm != null)
                    {
                        for (int i = 0; i < rm.Count; i++)
                            loaded.Remove(rm[i]);
                    }
                }
                var disps = _fMgDisposableAssets?.GetValue(cmObj) as IList;
                if (disps != null)
                {
                    for (int i = disps.Count - 1; i >= 0; i--)
                    {
                        if (disps[i] is Texture2D t && toDispose.Contains(t))
                            disps.RemoveAt(i);
                    }
                }
            }
            catch { }
        }

        private bool IsContentPatcherPackManager(object modContentMgr)
        {
            if (modContentMgr == null || (_cpPackNames.Count == 0 && _cpPackDirs.Count == 0))
                return false;
            try
            {
                string modName = _fModName?.GetValue(modContentMgr) as string;
                if (!string.IsNullOrEmpty(modName) && _cpPackNames.Contains(modName))
                    return true;
                string rootDir = _pFullRootDir?.GetValue(modContentMgr) as string;
                if (!string.IsNullOrEmpty(rootDir))
                {
                    string nd = NormalizeDir(rootDir);
                    for (int i = 0; i < _cpPackDirs.Count; i++)
                    {
                        if (string.Equals(nd, _cpPackDirs[i], StringComparison.OrdinalIgnoreCase))
                            return true;
                    }
                }
            }
            catch { }
            return false;
        }

        private bool IsEvictableAssetKey(string normKey, HashSet<string> activeKeys, HashSet<string> activeBasenames, bool prunePortraits)
        {
            if (string.IsNullOrEmpty(normKey))
                return false;

            // Safe off-screen HD/villager Portraits/* eviction (NPC.get_Portrait reloads cleanly on demand!)
            if (prunePortraits && normKey.StartsWith("portraits/", StringComparison.OrdinalIgnoreCase))
            {
                if (normKey.IndexOf("shop", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    normKey.IndexOf("answering", StringComparison.OrdinalIgnoreCase) >= 0)
                    return false;
                return true;
            }

            // Never touch Audio / Sound / UI / Fonts / Sprites / Buildings / TerrainFeatures / Characters
            if (normKey.StartsWith("loosesprites/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("fonts/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("tilesheets/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("terrainfeatures/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("buildings/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("characters/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("portraits/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("animals/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("monsters/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("minigames/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("data/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("strings/", StringComparison.OrdinalIgnoreCase) ||
                normKey.StartsWith("audio/", StringComparison.OrdinalIgnoreCase))
                return false;

            if (normKey.IndexOf("audio", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("sound", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("wave", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("music", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("minhhien", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("smallfont", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("dialoguefont", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("spritefont", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("loosesprites/font", StringComparison.OrdinalIgnoreCase) >= 0)
                return false;

            // Never touch shared global Maps/* assets held outside xTile.Map or reused on every outdoor warp
            if (normKey.IndexOf("springobjects", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("walls_and_floors", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("menutiles", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("world_map", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("worldmap", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("charactersheet", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("minecart", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("wallpaper", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("furniture", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("cursor", StringComparison.OrdinalIgnoreCase) >= 0 ||
                string.Equals(normKey, "maps/paths", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(normKey, "paths", StringComparison.OrdinalIgnoreCase))
                return false;

            // Never evict bobber, water, beach, animation, or fishing textures
            if (normKey.IndexOf("bobber", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("beach", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("water", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("animation", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("splash", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normKey.IndexOf("fishing", StringComparison.OrdinalIgnoreCase) >= 0)
                return false;

            // Keep current season's core outdoor/town/beach/forest/mountain tilesheets resident (avoids reload stutter & texture churn)
            string curSeason = Game1.currentSeason;
            if (!string.IsNullOrEmpty(curSeason) &&
                normKey.IndexOf(curSeason + "_", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (normKey.IndexOf("outdoorstilesheet", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 normKey.IndexOf("_town", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 normKey.IndexOf("_beach", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 normKey.IndexOf("_forest", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 normKey.IndexOf("_mountain", StringComparison.OrdinalIgnoreCase) >= 0))
                return false;

            // Must be a known map tilesheet or under Maps/
            bool isMapSheet = normKey.StartsWith("maps/", StringComparison.OrdinalIgnoreCase) ||
                              _knownTileSheetKeys.Contains(normKey);
            if (!isMapSheet)
                return false;

            // Never evict anything used by the current location's map!
            if (activeKeys.Contains(normKey))
                return false;
            string baseNm = GetBaseName(normKey);
            if (!string.IsNullOrEmpty(baseNm) && activeBasenames.Contains(baseNm))
                return false;

            return true;
        }

        private static string NormalizeAssetKey(string raw)
        {
            if (string.IsNullOrEmpty(raw))
                return string.Empty;
            string s = raw.Replace('\\', '/').Trim().TrimStart('/');
            if (s.EndsWith(".xnb", StringComparison.OrdinalIgnoreCase) ||
                s.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                s = s.Substring(0, s.Length - 4);
            // Strip SMAPI localized suffix like ".vi-VN", ".zh-CN", ".en"
            int dot = s.LastIndexOf('.');
            int slash = s.LastIndexOf('/');
            if (dot > slash && dot >= 0 && (s.Length - dot) <= 6)
            {
                string ext = s.Substring(dot + 1);
                if (ext.Length == 2 || (ext.Length == 5 && ext[2] == '-'))
                    s = s.Substring(0, dot);
            }
            return s.ToLowerInvariant();
        }

        private static string GetBaseName(string norm)
        {
            if (string.IsNullOrEmpty(norm)) return string.Empty;
            int idx = norm.LastIndexOf('/');
            return idx >= 0 ? norm.Substring(idx + 1) : norm;
        }

        private static string NormalizeDir(string dir)
        {
            return (dir ?? string.Empty).Replace('\\', '/').TrimEnd('/');
        }

        private static Type FindBaseTypeNamed(Type t, string simpleName)
        {
            while (t != null)
            {
                if (string.Equals(t.Name, simpleName, StringComparison.Ordinal))
                    return t;
                t = t.BaseType;
            }
            return null;
        }
    }
}
