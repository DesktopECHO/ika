"""Run pdlc --output-format rust"""

def _pdl_rust_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.run_shell(
        tools = [ctx.executable._pdlc],
        inputs = [ctx.file.src],
        outputs = [out],
        command = "{pdlc} --output-format {output_format} {src} > {out}".format(
            pdlc = ctx.executable._pdlc.path,
            output_format = ctx.attr.output_format,
            src = ctx.file.src.path,
            out = out.path,
        ),
    )
    return DefaultInfo(files = depset([out]))

pdl_rust = rule(
    implementation = _pdl_rust_impl,
    attrs = {
        "src": attr.label(allow_single_file = True),
        "out": attr.string(mandatory = True),
        "output_format": attr.string(
            default = "rust",
            values = ["rust", "rust_legacy"],
        ),
        "_pdlc": attr.label(
            # Reuse rootcanal's pdl compiler instead of generating a second
            # crate-universe toolchain for netsim.
            default = "@rootcanal//packets:pdlc",
            executable = True,
            cfg = "exec",
        ),
    },
)
