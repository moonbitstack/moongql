///|
/// Build the document's fragment table by name.
pub fn collect_fragments(doc : Document) -> Map[String, FragmentDefinition] {
  let m : Map[String, FragmentDefinition] = Map([])
  for def in doc.definitions {
    match def {
      FragmentDef(frag) => m[frag.name] = frag
      OperationDef(_) => ()
    }
  }
  m
}
