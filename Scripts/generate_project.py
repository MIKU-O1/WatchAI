#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project using only Python's standard library."""
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}
# Preserve the Team selected in Xcode when regenerating the project.
project_path = ROOT / "WatchAI.xcodeproj" / "project.pbxproj"
existing_project = project_path.read_text() if project_path.exists() else ""
team_match = re.search(r'DEVELOPMENT_TEAM = "?([A-Z0-9]{10})"?;', existing_project)
development_team = team_match.group(1) if team_match else ""
app_icon_name = next(name for name in ("AppIconScarf", "AppIconAvatar", "AppIconMint", "AppIcon")
                     if (ROOT / f"Sources/Watch/Assets.xcassets/{name}.appiconset").exists())


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def obj(key, isa, **fields):
    objects[uid(key)] = {"isa": isa, **fields}
    return uid(key)


def ref(path, kind):
    return obj("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=quote(path), sourceTree='"<group>"')


def build_config(name, sdk=None):
    settings = {
        "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES", "DEBUG_INFORMATION_FORMAT": quote("dwarf" if name == "Debug" else "dwarf-with-dsym"),
        "SWIFT_OPTIMIZATION_LEVEL": quote("-Onone" if name == "Debug" else "-O"),
    }
    if name == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    if sdk:
        settings.update({
            "SDKROOT": sdk,
            "SUPPORTED_PLATFORMS": quote("watchos watchsimulator"),
            "PRODUCT_NAME": quote("$(TARGET_NAME)"),
            "PRODUCT_BUNDLE_IDENTIFIER": quote("com.watchai.doubao.watchkitapp"),
            "INFOPLIST_FILE": quote("Config/Watch-Info.plist"),
            "GENERATE_INFOPLIST_FILE": "NO",
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": quote(development_team),
            "TARGETED_DEVICE_FAMILY": quote("4"),
            "ASSETCATALOG_COMPILER_APPICON_NAME": app_icon_name,
            "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
            "SKIP_INSTALL": "NO",
        })
        settings["WATCHOS_DEPLOYMENT_TARGET"] = "11.0"
    return settings


def configurations(scope, sdk=None):
    entries = [obj(f"config:{scope}:{name}", "XCBuildConfiguration", buildSettings=build_config(name, sdk), name=name) for name in ["Debug", "Release"]]
    return obj("configs:" + scope, "XCConfigurationList", buildConfigurations=entries,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


all_files = sorted([str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift")])
file_refs = {path: ref(path, "sourcecode.swift") for path in all_files}
for path in ["Sources/Watch/Assets.xcassets"]:
    file_refs[path] = ref(path, "folder.assetcatalog")
for path in ["Config/Watch-Info.plist", "README.md"]:
    file_refs[path] = ref(path, "text.plist.xml" if path.endswith("plist") else "text")
products = []
targets = {}
for name, sdk, folder in [("WatchAI Watch App", "watchos", "Watch")]:
    source_paths = [p for p in all_files if p.startswith(("Sources/Core/", "Sources/Shared/", f"Sources/{folder}/"))]
    sources = [obj(f"build:{name}:{p}", "PBXBuildFile", fileRef=file_refs[p]) for p in source_paths]
    asset = f"Sources/{folder}/Assets.xcassets"
    resources = [obj(f"build:{name}:{asset}", "PBXBuildFile", fileRef=file_refs[asset])]
    phases = [
        obj("sources:" + name, "PBXSourcesBuildPhase", buildActionMask="2147483647", files=sources, runOnlyForDeploymentPostprocessing="0"),
        obj("frameworks:" + name, "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
        obj("resources:" + name, "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
    ]
    product = obj("product:" + name, "PBXFileReference", explicitFileType="wrapper.application",
                  includeInIndex="0", path=quote(name + ".app"), sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    target = obj("target:" + name, "PBXNativeTarget", buildConfigurationList=configurations(name, sdk),
                 buildPhases=phases, buildRules=[], dependencies=[], name=quote(name), productName=quote(name),
                 productReference=product, productType=quote("com.apple.product-type.application"))
    targets[name] = target

product_group = obj("products", "PBXGroup", children=products, name="Products", sourceTree='"<group>"')
main_group = obj("main", "PBXGroup", children=list(file_refs.values()) + [product_group], sourceTree='"<group>"')
project = obj("project", "PBXProject", attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES"},
              buildConfigurationList=configurations("project"), compatibilityVersion=quote("Xcode 14.0"),
              developmentRegion="zh-Hans", hasScannedForEncodings="0", knownRegions=["en", '"zh-Hans"', "Base"],
              mainGroup=main_group, productRefGroup=product_group, projectDirPath='""', projectRoot='""', targets=list(targets.values()))


def render(value, indent=0):
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + render(v, indent + 1) + ",\n" for v in value) + "\t" * indent + ")"
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + k + " = " + render(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
    return str(value)


directory = ROOT / "WatchAI.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render({"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}) + "\n")
schemes = directory / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for name, target in targets.items():
    buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:WatchAI.xcodeproj"/>'
    (schemes / f"{name}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated", directory)
