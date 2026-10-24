#!/usr/bin/env python3
"""Generate the small Xcode wrapper around the dependency-free local Swift package."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
project = root / "SwiftSioyek.xcodeproj"
project.mkdir(exist_ok=True)
objects = []

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value))

def add(name, fields):
    key = ident(name)
    objects.append(f"\t\t{key} = {{ {fields} }};")
    return key

def array(values):
    return "(" + ", ".join(values) + ("," if values else "") + ")"

app_sources = sorted((root / "Sources/SwiftSioyek").glob("*.swift"))
ui_sources = sorted((root / "Tests/ReaderUITests").glob("*.swift"))
input_sources = sorted((root / "Tests/ReaderInputTests").glob("*.swift"))
refs = []
builds = {"app": [], "ui": [], "input": []}
for kind, files in [("app", app_sources), ("ui", ui_sources), ("input", input_sources)]:
    for file in files:
        relative = str(file.relative_to(root))
        ref = add("file:" + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")
        refs.append(ref)
        builds[kind].append(add("source:" + relative, f"isa = PBXBuildFile; fileRef = {ref};"))
        if kind == "app" and file.name in ["ReaderViewport.swift", "RenderCoordinator.swift", "PerformanceDiagnostics.swift"]:
            builds["input"].append(add("source:input:" + relative, f"isa = PBXBuildFile; fileRef = {ref};"))

icon_catalog = "Resources/Assets.xcassets"
icon_ref = add("file:" + icon_catalog, f"isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {quote(icon_catalog)}; sourceTree = SOURCE_ROOT;")
refs.append(icon_ref)
icon_build = add("resource:" + icon_catalog, f"isa = PBXBuildFile; fileRef = {icon_ref};")

app_product = add("app-product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = SwiftSioyek.app; sourceTree = BUILT_PRODUCTS_DIR;')
ui_product = add("ui-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ReaderUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
input_product = add("input-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ReaderInputTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = add("products", f"isa = PBXGroup; name = Products; children = {array([app_product, ui_product, input_product])}; sourceTree = \"<group>\";")
main_group = add("main-group", f"isa = PBXGroup; children = {array(refs + [products])}; sourceTree = \"<group>\";")
local_package = add("package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
package_products = {}
framework_builds = {"app": [], "ui": [], "input": []}
for product in ["ReaderCore", "ReaderPersistence", "PDFServices"]:
    ref = add("package:" + product, f"isa = XCSwiftPackageProductDependency; package = {local_package}; productName = {product};")
    package_products[product] = ref
    framework_builds["app"].append(add("link:app:" + product, f"isa = PBXBuildFile; productRef = {ref};"))
    if product == "PDFServices":
        framework_builds["ui"].append(add("link:ui:" + product, f"isa = PBXBuildFile; productRef = {ref};"))
    if product in ["ReaderCore", "PDFServices"]:
        framework_builds["input"].append(add("link:input:" + product, f"isa = PBXBuildFile; productRef = {ref};"))

config_lists = {}
for scope in ["project", "app", "ui", "input"]:
    configs = []
    for name in ["Debug", "Release"]:
        settings = {
            "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "27.0", "ARCHS": "arm64",
            "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete",
            "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if name == "Debug" else "",
            "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO",
        }
        if scope != "project":
            suffix = {"app": "", "ui": ".uitests", "input": ".inputtests"}[scope]
            settings.update({"CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "app.swiftsioyek" + suffix, "GENERATE_INFOPLIST_FILE": "NO" if scope == "app" else "YES"})
        if scope == "app":
            settings.update({"INFOPLIST_FILE": "Resources/Info.plist", "CODE_SIGN_ENTITLEMENTS": f"Resources/{name}.entitlements", "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "YES" if name == "Release" else "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "COMBINE_HIDPI_IMAGES": "YES"})
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
        if scope == "ui":
            settings.update({"TEST_TARGET_NAME": "SwiftSioyek", "SWIFT_EMIT_LOC_STRINGS": "NO"})
        body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
        configs.append(add(f"config:{scope}:{name}", f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};"))
    config_lists[scope] = add("config-list:" + scope, f"isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

for kind in ["app", "ui", "input"]:
    add("sources:" + kind, f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(builds[kind])}; runOnlyForDeploymentPostprocessing = 0;")
    add("frameworks:" + kind, f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {array(framework_builds[kind])}; runOnlyForDeploymentPostprocessing = 0;")

add("resources:app", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array([icon_build])}; runOnlyForDeploymentPostprocessing = 0;")

proxy = add("app-proxy", f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {ident('target:app')}; remoteInfo = SwiftSioyek;")
dependency = add("app-dependency", f"isa = PBXTargetDependency; target = {ident('target:app')}; targetProxy = {proxy};")
for kind, name, product, product_type in [("app", "SwiftSioyek", app_product, "com.apple.product-type.application"), ("ui", "ReaderUITests", ui_product, "com.apple.product-type.bundle.ui-testing"), ("input", "ReaderInputTests", input_product, "com.apple.product-type.bundle.unit-test")]:
    phases = [ident("sources:" + kind), ident("frameworks:" + kind)]
    if kind == "app":
        phases.append(ident("resources:app"))
    packages = list(package_products.values()) if kind == "app" else [package_products[p] for p in (["ReaderCore", "PDFServices"] if kind == "input" else ["PDFServices"])]
    add("target:" + kind, f"isa = PBXNativeTarget; buildConfigurationList = {config_lists[kind]}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array([dependency] if kind == 'ui' else [])}; name = {name}; packageProductDependencies = {array(packages)}; productName = {name}; productReference = {product}; productType = {quote(product_type)};")

project_id = add("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {config_lists['project']}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; packageReferences = ({local_package},); productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = {array([ident('target:app'), ident('target:ui'), ident('target:input')])};")
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 60;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project_id};\n}}\n")
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def build_ref(kind, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + kind)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:SwiftSioyek.xcodeproj"/>'
app_ref = build_ref("app", "SwiftSioyek", "SwiftSioyek.app")
ui_ref = build_ref("ui", "ReaderUITests", "ReaderUITests.xctest")
input_ref = build_ref("input", "ReaderInputTests", "ReaderInputTests.xctest")
(scheme_dir / "SwiftSioyek.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{input_ref}</TestableReference><TestableReference skipped="NO">{ui_ref}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
