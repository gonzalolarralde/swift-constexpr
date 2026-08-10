import ConstExpr
import ConstExprExampleDefinitions

public let exampleConstExprRegistry = #constExprRegistry(
    foo(_:),
    describe(prefix:number:),
    transform(_:) as (Int) -> String,
    transform(_:) as (String) -> String,
    total(_:),
    dictionarySummary(_:),
    route(x:),
    route(y:),
    int64Value,
    floatValue,
    characterValue,
    optionalValue(_:),
    acceptsInt64(_:),
    acceptsFloat(_:),
    acceptsCharacter(_:),
    typedValue as () -> Int,
    typedValue as () -> String,
    throwingValue(_:),
    exampleAnswer,
    Bar.self,
    ChainLeaf.self,
    Foo.self,
    FailableValue.self,
    ExampleStatus.self,
    ExampleBox.self
)
