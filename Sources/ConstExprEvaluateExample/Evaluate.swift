@freestanding(expression)
public macro evaluate<Result>(_ body: () -> Result) -> Result =
    #externalMacro(
        module: "ConstExprEvaluateExampleMacros",
        type: "ConstExprEvaluateExampleMacro"
    )
