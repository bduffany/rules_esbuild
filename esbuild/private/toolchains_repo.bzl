"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
Former will be always fetched,
and the latter will only be fetched when user actually needs to build <LANG> code.
"
The "complex computation" in our case is simply downloading large artifacts.
This guidance tells us how to avoid that: we put the toolchain targets in the alias repository
with only the toolchain attribute pointing into the platform-specific repositories.
"""

load("@bazel_skylib//lib:versions.bzl", "versions")

# Add more platforms as needed to mirror all the binaries
# published by the upstream project.
_PLATFORMS = {
    "darwin-x64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    ),
    "darwin-arm64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    ),
    "linux-x64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux-arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    ),
    "windows-x64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
    ),
}

# v0.16.0 renamed the artifacts.
# See release notes: https://github.com/evanw/esbuild/releases/tag/v0.16.0
# These names work for releases before that.
def get_platforms(version):
    if versions.is_at_least("0.16.0", version):
        return _PLATFORMS
    return {
        k.replace("-x64", "-64").replace("windows", "win32"): v
        for k, v in _PLATFORMS.items()
    }

def _toolchains_repo_impl(repository_ctx):
    # Expose a concrete toolchain which is the result of Bazel resolving the toolchain
    # for the execution or target platform.
    # Workaround for https://github.com/bazelbuild/bazel/issues/14009
    starlark_content = """# Generated by toolchains_repo.bzl

# Forward all the providers
def _resolved_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains["@aspect_rules_esbuild//esbuild:toolchain_type"]
    return [
        toolchain_info,
        toolchain_info.default,
        toolchain_info.esbuildinfo,
        toolchain_info.template_variables,
    ]

# Copied from java_toolchain_alias
# https://cs.opensource.google/bazel/bazel/+/master:tools/jdk/java_toolchain_alias.bzl
resolved_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = ["@aspect_rules_esbuild//esbuild:toolchain_type"],
    incompatible_use_toolchain_transition = True,
)
"""
    repository_ctx.file("defs.bzl", starlark_content)

    build_content = """# Generated by toolchains_repo.bzl
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the esbuild_register_toolchains macro
# so you don't normally need to interact with these targets.

load(":defs.bzl", "resolved_toolchain")

resolved_toolchain(name = "resolved_toolchain", visibility = ["//visibility:public"])

"""

    for [platform, meta] in get_platforms(repository_ctx.attr.esbuild_version).items():
        build_content += """
# Declare a toolchain Bazel will select for running the tool in an action
# on the execution platform.
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{platform}//:esbuild_toolchain",
    toolchain_type = "@aspect_rules_esbuild//esbuild:toolchain_type",
)
""".format(
            platform = platform,
            name = repository_ctx.attr.name,
            user_repository_name = repository_ctx.attr.user_repository_name,
            compatible_with = meta.compatible_with,
        )

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

toolchains_repo = repository_rule(
    _toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected.""",
    attrs = {
        "esbuild_version": attr.string(doc = "version of esbuild"),
        "user_repository_name": attr.string(doc = "what the user chose for the base name"),
    },
)
