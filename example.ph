let x : int := 1

def h() -> void:
  pass

class Hola:
  init:
    Hola(i: int):
      pass

  def f(d : float) -> int:
    let de : string := 'hola'
    pass

def g(i : int) -> int:
  let b : bool := True
  if True:
    return 5
  for j :int := 0 : True : j := j + 1:
    if False:
      i := 200
      break
    else
      continue
  
  let c : int := 5
  if c == 5:
    return 1

  return 2

main:
  create a : Hola(5)
  g(2)
  while True:
    print(1)
