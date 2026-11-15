namespace Fixture

@[export fixture_add]
def add (a b : UInt64) : UInt64 := a + b

@[export fixture_greet]
def greet (s : String) : String := "hello, " ++ s

@[export fixture_even]
def even (n : UInt64) : Bool := n % 2 == 0

@[export fixture_double]
def double (n : Nat) : Nat := n * 2

@[export fixture_flip]
def flip (b : Bool) : Bool := !b

end Fixture
