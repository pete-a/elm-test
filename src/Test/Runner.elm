module Test.Runner
    exposing
        ( Runnable
        , Runner(..)
        , run
        , fromTest
        , getFailure
        , isTodo
        , formatLabels
        , Shrinkable
        , fuzz
        , shrink
        )

{-| This is an "experts only" module that exposes functions needed to run and
display tests. A typical user will use an existing runner library for Node or
the browser, which is implemented using this interface. A list of these runners
can be found in the `README`.

## Runner

@docs Runner, fromTest

## Runnable

@docs Runnable, run

## Expectations

@docs getFailure, isTodo

## Formatting

@docs formatLabels

## Fuzzers
These functions give you the ability to run fuzzers separate of running fuzz tests.

@docs Shrinkable, fuzz, shrink
-}

import Test exposing (Test)
import Test.Internal as Internal
import Test.Expectation
import Test.Message exposing (failureMessage)
import RoseTree exposing (RoseTree(Rose))
import Lazy.List as LazyList exposing (LazyList)
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Fuzz.Internal
import Random.Pcg
import String


{-| An unevaluated test. Run it with [`run`](#run) to evaluate it into a
list of `Expectation`s.
-}
type Runnable
    = Thunk (() -> List Expectation)


{-| A structured test runner, incorporating:

* The expectations to run
* The hierarchy of description strings that describe the results
-}
type Runner
    = Runnable Runnable
    | Labeled String Runner
    | Batch (List Runner)


{-| Evaluate a [`Runnable`](#Runnable) to get a list of `Expectation`s.
-}
run : Runnable -> List Expectation
run (Thunk fn) =
    fn ()


{-| Convert a `Test` into a `Runner`.

In order to run any fuzz tests that the `Test` may have, it requires a default run count as well
as an initial `Random.Pcg.Seed`. `100` is a good run count. To obtain a good random seed, pass a
random 32-bit integer to `Random.Pcg.initialSeed`. You can obtain such an integer by running
`Math.floor(Math.random()*0xFFFFFFFF)` in Node. It's typically fine to hard-code this value into
your Elm code; it's easy and makes your tests reproducible.
-}
fromTest : Int -> Random.Pcg.Seed -> Test -> Runner
fromTest runs seed test =
    if runs < 1 then
        Thunk (\() -> [ Expect.fail ("Test runner run count must be at least 1, not " ++ toString runs) ])
            |> Runnable
    else
        case test of
            Internal.Test run ->
                Thunk (\() -> run seed runs)
                    |> Runnable

            Internal.Labeled label subTest ->
                subTest
                    |> fromTest runs seed
                    |> Labeled label

            Internal.Batch subTests ->
                subTests
                    |> List.foldl (distributeSeeds runs) ( seed, [] )
                    |> Tuple.second
                    |> Batch


distributeSeeds : Int -> Test -> ( Random.Pcg.Seed, List Runner ) -> ( Random.Pcg.Seed, List Runner )
distributeSeeds runs test ( startingSeed, runners ) =
    case test of
        Internal.Test run ->
            let
                ( seed, nextSeed ) =
                    Random.Pcg.step Random.Pcg.independentSeed startingSeed
            in
                ( nextSeed, runners ++ [ Runnable (Thunk (\() -> run seed runs)) ] )

        Internal.Labeled label subTest ->
            let
                ( nextSeed, nextRunners ) =
                    distributeSeeds runs subTest ( startingSeed, [] )

                finalRunners =
                    List.map (Labeled label) nextRunners
            in
                ( nextSeed, runners ++ finalRunners )

        Internal.Batch tests ->
            let
                ( nextSeed, nextRunners ) =
                    List.foldl (distributeSeeds runs) ( startingSeed, [] ) tests
            in
                ( nextSeed, [ Batch (runners ++ nextRunners) ] )


{-| Return `Nothing` if the given [`Expectation`](#Expectation) is a [`pass`](#pass).

If it is a [`fail`](#fail), return a record containing the failure message,
along with the given inputs if it was a fuzz test. (If no inputs were involved,
the record's `given` field will be `Nothign`).

For example, if a fuzz test generates random integers, this might return
`{ message = "it was supposed to be positive", given = "-1" }`

    getFailure (Expect.fail "this failed")
    -- Just { message = "this failed", given = "" }

    getFailure (Expect.pass)
    -- Nothing
-}
getFailure : Expectation -> Maybe { given : Maybe String, message : String }
getFailure expectation =
    case expectation of
        Test.Expectation.Pass ->
            Nothing

        Test.Expectation.Fail record ->
            Just
                { given = record.given
                , message = failureMessage record
                }


{-| Determine if an expectation was created by a call to `Test.todo`. Runners
may treat these tests differently in their output.
-}
isTodo : Expectation -> Bool
isTodo expectation =
    case expectation of
        Test.Expectation.Pass ->
            False

        Test.Expectation.Fail { reason } ->
            reason == Test.Expectation.TODO


{-| A standard way to format descriptions and test labels, to keep things
consistent across test runner implementations.

The HTML, Node, String, and Log runners all use this.

What it does:

* drop any labels that are empty strings
* format the first label differently from the others
* reverse the resulting list

    [ "the actual test that failed"
    , "nested description failure"
    , "top-level description failure"
    ]
        |> formatLabels ((++) "↓ ") ((++) "✗ ")

    {-
        [ "↓ top-level description failure"
        , "↓ nested description failure"
        , "✗ the actual test that failed"
        ]
    -}

-}
formatLabels :
    (String -> format)
    -> (String -> format)
    -> List String
    -> List format
formatLabels formatDescription formatTest labels =
    case List.filter (not << String.isEmpty) labels of
        [] ->
            []

        test :: descriptions ->
            descriptions
                |> List.map formatDescription
                |> (::) (formatTest test)
                |> List.reverse


type alias Shrunken a =
    { down : LazyList (RoseTree a)
    , over : LazyList (RoseTree a)
    }


{-| A `Shrinkable a` is an opaque type that allows you to obtain a value of type
`a` that is smaller than the one you've previously obtained.
-}
type Shrinkable a
    = Shrinkable (Shrunken a)


{-| Given a fuzzer, return a random generator to produce a value and a
Shrinkable. The value is what a fuzz test would have received as input.
-}
fuzz : Fuzzer a -> Random.Pcg.Generator ( a, Shrinkable a )
fuzz fuzzer =
    Fuzz.Internal.unpackGenTree fuzzer
        |> Random.Pcg.map
            (\(Rose root children) ->
                ( root, Shrinkable { down = children, over = LazyList.empty } )
            )


{-| Given a Shrinkable, attempt to shrink the value further. Pass `False` to
indicate that the last value you've seen (from either `fuzz` or this function)
caused the test to **fail**. This will attempt to find a smaller value. Pass
`True` if the test passed. If you have already seen a failure, this will attempt
to shrink that failure in another way. In both cases, it may be impossible to
shrink the value, represented by `Nothing`.
-}
shrink : Bool -> Shrinkable a -> Maybe ( a, Shrinkable a )
shrink causedPass (Shrinkable { down, over }) =
    let
        tryNext =
            if causedPass then
                over
            else
                down
    in
        case LazyList.headAndTail tryNext of
            Just ( Rose root children, tl ) ->
                Just ( root, Shrinkable { down = children, over = tl } )

            Nothing ->
                Nothing
