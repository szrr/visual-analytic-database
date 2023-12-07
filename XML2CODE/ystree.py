#!/usr/bin/python
"""
   Copyright (c) 2012-2013 The Ohio State University.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
"""




from xml.dom import minidom, Node
import copy
import sys
from schema import global_table_dict, process_schema_in_a_file, ColumnSchema, TableSchema
import main

############################################################################################
############################################################################################
########################    global info         ############################################
############################################################################################
############################################################################################

agg_func_list = ["SUM","AVG","COUNT","MAX","MIN","COUNT_DISTINCT","VIDEO_SIMILARITY","OUTLIER_LINE","OUTLIER_SCORE"]

# subqueries are generated as query plans before their parents
subqueries = []


############################################################################################
############################################################################################
########################    Exp Class           ############################################
############################################################################################
############################################################################################

class YExpTool:

    token_list = ["ID", "DOT", "ASTERISK", "COMMA", "LPAREN", "RPAREN", "'SUM'", "'AVG'", "'MAX'", "'MIN'", "'COUNT'", "NUMBER", "QUOTED_STRING", "DIVIDE", "PLUS", "MINUS"]

    token_list_agg_func = ["'SUM'", "'AVG'", "'MAX'", "'MIN'", "'COUNT'", "'VIDEO_SIMILARITY'", "'OUTLIER_LINE'", "'OUTLIER_SCORE'"]

    vector_func = ["'DISTANCE'", "'EXTRACTION'", "'FEATURE_DISTANCE'", "'OUTLIER_LINE'", "'OUTLIER_SCORE'", "'VIDEO_SIMILARITY'", "'KNN_AVG_DISTANCE'", "'KNN'", "'VIDEO_EXTRACTION'"]  # "'KNN'" #add_new_grammar

    def __init__(self):
        pass

    def convert_token_list_to_exp_tree(self, input_token_list):

        len_input_token_list = len(input_token_list)

        if len_input_token_list == 1:

            a_token = input_token_list[0]
            atc = a_token["content"]
            atn = a_token["name"]

            if atn == "ID":
                return YRawColExp("", atc)
            elif atn == "ASTERISK":
                return YRawColExp("", "*")
            elif atn == "NUMBER":
                return YConsExp(atc, "DECIMAL")
            elif atn == "QUOTED_STRING":
                atc = atc.lstrip("'")
                atc = atc.rstrip("'")
                atc = "\"" + atc + "\""
                return YConsExp(atc, "TEXT")
            elif atn == "VECTOR": # add new grammar
                # handle vector like: [f1, f2, ..., fn]
                # atc = atc.lstrip("[")
                # atc = atc.rstrip("]")
                return YConsExp(atc, "VECTOR")
            elif atn == "PATH": # add new grammar
                # handle path like: /mnt/ssd1/szr/image.png
                return YConsExp(atc, "PATH")
            elif atn == "T_RESERVED" and atc.upper() == "NULL":
                return YConsExp(atc, "NULL")


        if len_input_token_list == 3:

            first_token = input_token_list[0]
            second_token = input_token_list[1]
            third_token = input_token_list[2]

            #table.column
            if first_token["name"] == "ID" and second_token["name"] == "DOT" and third_token["name"] == "ID":
                return YRawColExp(first_token["content"], third_token["content"])

            #table.*
            if first_token["name"] == "ID" and second_token["name"] == "DOT" and third_token["name"] == "ASTERISK":
                return YRawColExp(first_token["content"], "*")

            #func()
            if first_token["name"] == "ID" and second_token["name"] == "LPAREN" and third_token["name"] == "RPAREN":
                return YFuncExp(first_token["name"], [])


        if len_input_token_list >= 3 and len_input_token_list % 2 == 1: 
            commas = input_token_list[1::2]
            if all(map(lambda t: t["name"] == "COMMA", commas)):
                cons = input_token_list[0::2]
                return YFuncExp( "LIST", map(lambda t: self.convert_token_list_to_exp_tree([t]), cons) )




        #todo: we also should consider: count(*)

        #---------------------------------------------------------------
        #Step 0: look for boolean expression: "<" ">" "<>" "like" "is"   ---? Not Like?
        #---------------------------------------------------------------

        sub_level = 0

        first_xiaoyu_index = -1
        first_dayu_index = -1
        first_dengyu_index = -1
        first_like_index = -1
        first_is_index = -1

        partition_index = -1
        partition_type = None

        for i in range(0, len_input_token_list):
            a_token = input_token_list[i]

            atc = a_token["content"]
            atn = a_token["name"]

            if atn == "LPAREN":
                sub_level += 1
            elif atn == "RPAREN":
                sub_level -= 1

            if sub_level != 0:
                continue

            if atn == "T_RESERVED" and atc.upper() == "LIKE":
                partition_index = i
                partition_type = "LIKE"
                continue
            elif atn == "T_RESERVED" and atc.upper() == "IS":
                partition_index = i
                partition_type = "IS"
                continue
            elif atn == "T_RESERVED" and atc.upper() == "IN":
                partition_index = i
                partition_type = "IN"
                continue
            elif atn in ["EQ", "GTH", "LTH", "NOT_EQ", "GEQ", "LEQ"]:
                partition_index = i
                partition_type = atn
                continue


        if partition_index > 0:

            func_name = partition_type

            before_list = input_token_list[:partition_index]
            after_list = input_token_list[(partition_index + 1):]

            before_exp = self.convert_token_list_to_exp_tree(before_list)
            if partition_type == "LIKE":
                if len(after_list) != 1:
                    print "only one string is permitted after LIKE"
                    exit(1)

                pattern = after_list[0]['content'].lstrip("'").rstrip("'")

                substrs = map(lambda s: "'" + s + "'", pattern.split("%"))
                end_exp = YFuncExp( "LIST", map(lambda sub: self.convert_token_list_to_exp_tree([{'content': sub, 'name': 'QUOTED_STRING'}]), substrs) )
            else:
                end_exp = self.convert_token_list_to_exp_tree(after_list)

            return YFuncExp(func_name, [before_exp, end_exp])


        #---------------------------------------------------------------
        #Step 1: look for plus or minus
        #---------------------------------------------------------------

        sub_level = 0

        first_plus_index = -1
        first_minus_index = -1

        for i in range(0, len_input_token_list):
            a_token = input_token_list[i]

            atc = a_token["content"]
            atn = a_token["name"]


            if atn == "LPAREN":
                sub_level += 1
            elif atn == "RPAREN":
                sub_level -= 1

            if sub_level != 0:
                continue

            if atn == "PLUS":
                first_plus_index = i
                continue
            elif atn == "MINUS":
                first_minus_index = i
                continue


        if first_plus_index > 0:
            before_list = input_token_list[:first_plus_index]
            after_list = input_token_list[(first_plus_index + 1):]

            before_exp = self.convert_token_list_to_exp_tree(before_list)
            end_exp = self.convert_token_list_to_exp_tree(after_list)

            return YFuncExp("PLUS", [before_exp, end_exp])

        elif first_minus_index > 0:
            before_list = input_token_list[:first_minus_index]
            after_list = input_token_list[(first_minus_index + 1):]

            before_exp = self.convert_token_list_to_exp_tree(before_list)
            end_exp = self.convert_token_list_to_exp_tree(after_list)

            return YFuncExp("MINUS", [before_exp, end_exp])


        #---------------------------------------------------------------
        #Step 2: look for multiply and divide
        #---------------------------------------------------------------

        sub_level = 0

        first_multiply_index = -1
        first_divide_index = -1

        for i in range(0, len_input_token_list):
            a_token = input_token_list[i]

            atc = a_token["content"]
            atn = a_token["name"]


            if atn == "LPAREN":
                sub_level += 1
            elif atn == "RPAREN":
                sub_level -= 1

            if sub_level != 0:
                continue

            if atn == "ASTERISK":
                first_multiply_index = i
                continue
            elif atn == "DIVIDE":
                first_divide_index = i
                continue


        if first_multiply_index > 0:
            before_list = input_token_list[:first_multiply_index]
            after_list = input_token_list[(first_multiply_index + 1):]

            before_exp = self.convert_token_list_to_exp_tree(before_list)
            end_exp = self.convert_token_list_to_exp_tree(after_list)

            return YFuncExp("MULTIPLY", [before_exp, end_exp])

        elif first_divide_index > 0:
            before_list = input_token_list[:first_divide_index]
            after_list = input_token_list[(first_divide_index + 1):]

            before_exp = self.convert_token_list_to_exp_tree(before_list)
            end_exp = self.convert_token_list_to_exp_tree(after_list)

            return YFuncExp("DIVIDE", [before_exp, end_exp])


        #---------------------------------------------------------------
        #Step 3: func() or ()
        #---------------------------------------------------------------

        first_token = input_token_list[0]
        t_n = first_token["name"]
        if t_n == "ID" or t_n in self.vector_func or t_n in self.token_list_agg_func:
            #func(a,b,c)
            func_name = first_token["content"]
            #we process a, b,c ...
            second_token = input_token_list[1]
            last_token = input_token_list[-1]

            if second_token["name"] != "LPAREN" or last_token["name"] != "RPAREN":
                print >>sys.stderr,input_token_list
                exit(29)


            sub_level = 0

            t_para_list = []
            a_para_list = []

            for i in range(2, len_input_token_list - 1):
                a_token = input_token_list[i]

                a_para_list.append(a_token)

                atc = a_token["content"]
                atn = a_token["name"]


                if atn == "LPAREN":
                    sub_level += 1
                elif atn == "RPAREN":
                    sub_level -= 1


                if sub_level == 0 and atn == "COMMA":
                    a_para_list = a_para_list[:-1]
                    t_list = []
                    for ai in a_para_list:
                        t_list.append(ai)
                    t_para_list.append(t_list)

                    a_para_list = []

            t_para_list.append(a_para_list)


            para_exp_list = []
            for ap in t_para_list:
                para_exp_list.append(self.convert_token_list_to_exp_tree(ap))

            filter = project = extract = path = None
            # if func is DISTANCE() or OUTLIER_SCORE()
            if func_name == "DISTANCE":
                if isinstance(para_exp_list[1], YFuncExp): # DISTANCE(vector, EXTRACTION(path))
                    filter = 1
                    extract = 1
                    path = 1
                elif isinstance(para_exp_list[1], YConsExp): # DISTANCE(vector, path)
                    filter = 1
                    extract = None
                    path = 1
                elif isinstance(para_exp_list[1], YRawColExp): # DISTANCE(vector, vector)
                    filter = extract = path = None

            if func_name == "KNN_AVG_DISTANCE":
                project = 1
            return YFuncExp(func_name, para_exp_list, project, filter, extract, path)

        elif first_token["name"] == "LPAREN":

            last_token = input_token_list[-1]

            if last_token["name"] == "RPAREN":
                return self.convert_token_list_to_exp_tree(input_token_list[1:-1])

            else:
                print >>sys.stderr,input_token_list, last_token
                exit(29)

        elif first_token["name"] == "SUBQ":
            last_token = input_token_list[-1]
            # at least four tokens: SUBQ, (, SUBQREF, )
            if len(input_token_list) >= 4 and last_token["name"] == "RPAREN":
                par_list = []
                for token in input_token_list[2:-1]:
                    if token["name"] == "COMMA":
                        continue
                    elif token["name"] == "ID":
                        par_list.append( YRawColExp("", token["content"]) )
                    elif token["name"] == "SUBQREF":
                        par_list.append( YConsExp(token["content"], "DECIMAL") )
                    else:
                        print "Unknown parameter for SUBQ: ", token
                        exit(99)

                return YFuncExp("SUBQ", par_list)

            else:
                print >>sys.stderr,input_token_list, last_token
                exit(29)

        else:
            print >>sys.stderr,input_token_list, first_token
            exit(29)


class YExpBase:

    #exp_type could be: FuncExp, ConsExp, RawColExp, and ColExp
    exp_type = None

    def __init__(self):
        pass

    def evaluate(self):
        pass

class YFuncExp(YExpBase):

    func_name = None
    parameter_list = None
    func_obj = None
    # parameters for distance() and outlier_score()
    project_res_index = None
    filter_func = None
    extract_feature = None
    have_path = None
    inner = None
    func_list_index = None



    def __init__(self, input_func_name, input_parameter_list, project = None, filter = None, extract = None, path = None):

        self.func_name = input_func_name.upper()
        self.parameter_list = input_parameter_list
        self.project_res_index = project
        self.filter_func = filter
        self.extract_feature = extract
        self.have_path = path
        self.convert_to_upper()
        self.gen_func_obj(self)

    def set_para_list(self,para_list):
        self.parameter_list = para_list
        self.gen_func_obj(self)


    def evaluate(self):

        ps = ""
        for ap in self.parameter_list:
            aps = ap.evaluate()
            ps = ps + str(aps) + ","

        ps = ps[:-1]

        return self.func_name + "(" + ps + ")"

    def gen_func_obj(self,obj):
        self.func_obj = obj
        for x in self.parameter_list:
            x.gen_func_obj(self)

### replace an exp in the parameter_list
    def replace(self,old_exp,new_exp):
        new_list = []
        for x in self.parameter_list:
            if x.compare(old_exp) is True:
                new_list.append(new_exp)
            else:
                new_list.append(x)
        self.set_para_list(new_list)

    def convert_to_upper(self):

        for x in self.parameter_list:
            x.convert_to_upper()

    def has_groupby_func(self):
        res =False

        if self.func_name in agg_func_list:
            return True

        for x in self.parameter_list:
            res = res | x.has_groupby_func()
        return res

    def get_value_type(self):
        return "DECIMAL"

    def get_exp_type(self):
        return "Func"

    def compare(self,exp):
        if self.get_exp_type() != exp.get_exp_type():
            return False
        if self.func_name != exp.func_name:
            return False
        if len(self.parameter_list) != len(exp.parameter_list):
            return False
        for i in range(0,len(self.parameter_list)):
            if self.parameter_list[i].compare(exp.parameter_list[i]) is False:
                return False

        return True


class YConsExp(YExpBase):

    cons_type = None

    cons_value = None

    # In a subquery, This indicates what column it refers to
    ref_col = None

    def __init__(self, input_cons_value, input_cons_type):

        self.cons_value = input_cons_value
        self.cons_type = input_cons_type

    def evaluate(self):
        if self.ref_col == None:
            return self.cons_value
        else:
            return "Cons(ref. to " + self.ref_col.evaluate() + ")"

    def gen_func_obj(self,func_obj):
        return

    def convert_to_upper(self):
        pass

    def has_groupby_func(self):
        return False

    def get_value_type(self):
        return self.cons_type

    def get_exp_type(self):
        return "Cons"

    def compare(self,exp):
        if self.get_exp_type() != exp.get_exp_type():
            return False

        if self.cons_type !=exp.cons_type or self.cons_value != exp.cons_value:
            return False

        return True


class YRawColExp(YExpBase):


    table_name = None
    column_name = None
    column_type = None
    func_obj = None
    past_table_name = None

    def __init__(self, input_table_name, input_column_name):

        self.table_name = input_table_name.upper()
        self.column_name = str(input_column_name).upper()
        self.column_type = None
        self.func_obj = None

    def evaluate(self):
        if self.table_name == "":
            return "UNKNOWNTABLE" + "." + self.column_name
        return self.table_name + "." + str(self.column_name)

    def gen_func_obj(self,func_obj):
        self.func_obj = func_obj

    def convert_to_upper(self):
### the column_name can be either string  or number (index)
        if type(self.column_name) is str:
            self.column_name = self.column_name.upper()
        self.table_name = self.table_name.upper()

    def has_groupby_func(self):
        return False

    def get_value_type(self):
        if self.column_type is not None:
            pass
        elif self.table_name == "":
            col_res = lookup_a_column(self.column_name)
            self.column_type = col_res[0].table_schema.get_column_type_by_name(self.column_name)
        else:
            col_res = lookup_a_column(self.column_name)
            for tmp in col_res:
                if tmp.table_schema.table_name == self.table_name:
                    self.column_type = tmp.table_schema.get_column_type_by_name(self.column_name)

        return self.column_type

    def get_exp_type(self):
        return "Col"

    def compare(self,exp):
        if self.get_exp_type() != exp.get_exp_type():
            return False

        if self.column_name != exp.column_name or self.table_name != exp.table_name:
            return False

        return True

############################################################################################
############################################################################################
########################    InitialQueryTree    ############################################
############################################################################################
############################################################################################

#Sub-types could be: TableNode, SelectProjectNode, GroupByNode, OrderByNode, TwoJoinNode, MultipleJoinNode
class QueryPlanTreeBase(object):

    name = None
    correlated = False

    source = None
    i_am_the_tree = None

    select_list = None

    #Not all nodes can have where_condition
    #but, a GroupByNode node can get where_condition from its parents
    where_condition = None

    group_by_clause = None

    having_clause = None
    order_by_clause = None

    table_list = []
    table_alias_dict = {}
    dynamic_values = {} # a dictionary storing dynamic values from upper level columns
                        # key: column name, value: value
    def __init__(self):

        self.table_list = []
        self.table_alias_dict = {}
        self.dynamic_values = {}

    def release_order_by(self):

        if self.order_by_clause is not None:
            ob = OrderByNode()
            ob.source = self.source
            ob.i_am_the_tree = self.i_am_the_tree
            ob.select_list = None #or self.select_list? to be done!

            ob.order_by_clause = self.order_by_clause
            self.order_by_clause = None

            for x in self.table_list:
                ob.table_list.append(x)
            for x in self.table_alias_dict.keys():
                ob.table_alias_dict[x] = self.table_alias_dict[x]
            for x in self.dynamic_values:
                ob.dynamic_values[x] = self.dynamic_values[x]

            ob.child = self
            self.parent = ob
            return ob
        else:
            return self


    def release_group_by(self):

        if self.group_by_clause is not None:

            gb = GroupByNode()
            gb.source = self.source
            gb.i_am_the_tree = self.i_am_the_tree

            gb.select_list = copy.deepcopy(self.select_list)

            gb.group_by_clause = self.group_by_clause
            self.group_by_clause = None


            if self.having_clause is not None:
                gb.having_clause = self.having_clause
                self.having_clause = None

            gb.child = self
            self.parent = gb

            for x in self.table_list:
                if x not in gb.table_list:
                    gb.table_list.append(x)
            gb.table_alias_dict = self.table_alias_dict
            gb.dynamic_values = self.dynamic_values

            return gb

        else:
            if self.select_list is None:
                return self

            select_dict = self.select_list.dict_exp_and_alias

            agg_bool = False

            for x in select_dict.keys():
                agg_bool = agg_bool | x.has_groupby_func()

            if agg_bool is False:
                return self

            gb = GroupByNode()
            gb.source = self.source
            gb.i_am_the_tree = self.i_am_the_tree

            gb.select_list = copy.deepcopy(self.select_list)
            gb.group_by_clause = FirstStepGroupBy(None)
            gb_exp = YConsExp(1,"INTEGER")
            gb.group_by_clause.groupby_exp_list.append(gb_exp)
            self.group_by_clause = None

            for x in self.table_list:
                if x not in gb.table_list:
                    gb.table_list.append(x)
            gb.table_alias_dict = self.table_alias_dict
            gb.dynamic_values = self.dynamic_values

            gb.child = self
            self.parent = gb

            return gb


    def convert_to_binary_join_tree(self):

        return self


    def debug(self, level):
        pass

class OrderByNode(QueryPlanTreeBase):
    child = None
    parent = None
    composite = None
    output = None

    def __init__(self):
        super(OrderByNode, self).__init__()

    def release_order_by(self):
        print >>sys.stderr,"OrderByNode Internal Error"
        exit(29)

    def release_group_by(self):
        self.child = self.child.release_group_by()
        return super(OrderByNode, self).release_group_by()

    def convert_to_binary_join_tree(self):
        self.child = self.child.convert_to_binary_join_tree()
        self.child.parent = self
        return super(OrderByNode, self).convert_to_binary_join_tree()

    def get_pk(self):
        return []

    def set_composite(self,c_node,node):
        self.composite = c_node

    def adjust_index(self,exp_list,table_name):
        return

    def get_mapoutput(self,table_name):
        return copy.deepcopy(self.child.select_list.tmp_exp_list)

    def get_mapfiler(self,table_name):
        return self.child.where_condition

    def debug(self, level):
        pb = ""
        for i in range(level):
            pb += "    "

        xes = ""
        for x in self.order_by_clause.orderby_exp_list:
            xes = xes + x.evaluate()
            xes = xes + ","

        i = ""
        for y in self.order_by_clause.order_indicator_list:
            i = i + y
            i = i + ","

        name = "None" if self.name is None else self.name
        star = "*" if self.correlated else ""
        print pb, star + "OrderByNode", "(" + name + ")", "[" + xes + "]", "[" + i + "]"


        self.child.debug(level + 1)

class GroupByNode(QueryPlanTreeBase):

    child = None
    parent = None
    composite = None

    def __init__(self):
        super(GroupByNode, self).__init__()

    def release_order_by(self):
        print >>sys.stderr,"GroupByNode Internal Error:release orderby"
        exit(29)

    def release_group_by(self):
        print >>sys.stderr,"GroupByNode Internal Error:release groupby"
        exit(29)

    def convert_to_binary_join_tree(self):
        self.child = self.child.convert_to_binary_join_tree()
        self.child.parent = self
        return super(GroupByNode, self).convert_to_binary_join_tree()

# the get_pk function should be called after generating the index
### fix me here: need to add more choices for the pk_list

    def get_pk(self):
        ret_exp_list = []
        gb_exp_list = []
        for x in self.group_by_clause.groupby_exp_list:
            new_exp = __trace_to_leaf__(self,x,False)
            tmp = []
            tmp.append(new_exp)
            ret_exp_list.append(tmp)
            gb_exp_list.append(new_exp)

        ret_exp_list.append(gb_exp_list)
        return ret_exp_list

    def set_composite(self,c_node,node):
        self.composite = c_node

    def adjust_index(self,exp_list,table_name):
        for x in self.select_list.tmp_exp_list:
            if isinstance(x,YRawColExp):
                    index = x.column_name
                    tmp_exp = self.child.select_list.tmp_exp_list[index]
                    for y in exp_list:
                        if tmp_exp.compare(y) is True:
                            x.column_name = exp_list.index(y)
                            break
            elif isinstance(x,YFuncExp):
                    col_list = []
                    __get_func_para__(x,col_list)
                    for y in col_list:
                        index = y.column_name
                        tmp_exp = self.child.select_list.tmp_exp_list[index]
                        for z in exp_list:
                            if tmp_exp.compare(z):
                                y.column_name = exp_list.index(z)
                                break

        if self.where_condition is not None:
            col_list = []
            __get_func_para__(self.where_condition.where_condition_exp,col_list)
            for x in col_list:
                if x.table_name != "AGG":
                    index = int(x.column_name)
                    tmp_exp = self.child.select_list.tmp_exp_list[index]
                    for y in exp_list:
                        if tmp_exp.compare(y):
                            x.column_name = exp_list.index(y)
                            break

    def get_mapoutput(self,table_name):
        return copy.deepcopy(self.child.select_list.tmp_exp_list)

    def get_mapfilter(self,table_name):
        return self.child.where_condition

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += "    "

        if self.select_list is None:
            sscs = str(None)
        else:
            sscs = self.select_list.converted_exp_str

        hs = ""
        if self.having_clause is not None:
            hs = self.having_clause.where_condition_exp.evaluate()

        name = "None" if self.name is None else self.name
        star = "*" if self.correlated else ""
        print pb, star + "GroupByNode", "(" + name + ")", "[" + sscs + "]", "[" + self.group_by_clause.converted_exp_str + "]", "[" + hs + "]"
        self.child.debug(level + 1)


class SelectProjectNode(QueryPlanTreeBase):

    child = None
    parent = None
    composite = None
    table_alias = None
    table_name = None

    in_table_list = []
    in_table_alias_dict = {}

    def __init__(self):

        self.in_table_list = []
        self.in_table_alias_dict = {}

        super(SelectProjectNode, self).__init__()

    def release_order_by(self):
        self.child = self.child.release_order_by()

        return super(SelectProjectNode,self).release_order_by()

    def release_group_by(self):
        self.child = self.child.release_group_by()

        return super(SelectProjectNode,self).release_group_by()

    def convert_to_binary_join_tree(self):
        self.child = self.child.convert_to_binary_join_tree()
        self.child.parent = self

        return super(SelectProjectNode,self).convert_to_binary_join_tree()

    def get_pk(self):
        return self.child.get_pk()

    def get_mapoutput(self,table_name):
        return self.child.get_mapoutput(table_name)

    def get_mapfilter(self,table_name):
        return self,child.get_mapfilter(table_name)

    def set_composite(self,c_node,node):
        if self.parent is not None:
            self.parent.set_composite(c_node,self)

    def adjust_index(self,exp_list,table_name):
        self.child.adjust_index(exp_list,table_name)

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += "    "


        if self.select_list is None:
            sscs = str(None)
        else:
            sscs = self.select_list.converted_exp_str


        if self.where_condition is None:
            swc = str(None)
        else:
            swc = self.where_condition.converted_exp_str

        name = "None" if self.name is None else self.name
        star = "*" if self.correlated else ""
        print pb, star + "SelectProjectNode", "(" + name + ")", self.table_alias, "[" + sscs + "]", "[" + swc + "]"
        self.child.debug(level + 1)



class TableNode(QueryPlanTreeBase):

    parent = None
    composite = None
    table_name = None
    table_alias = None
    project_func_list = None
    func_list = None
    func_alias = None

    def __init__(self):
        super(TableNode, self).__init__()

    def set_composite(self,c_node,node):
        return

    def get_pk(self):
        return []

    def get_mapoutput(self,table_name):
        return copy.deepcopy(self.select_list.tmp_exp_list)

    def get_mapfilter(self,table_name):
        return self.child.where_condition

    def adjust_index(self,exp_list,table_name):
        return

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += "    "

        if self.select_list is None:
            sscs = str(None)
        else:
            sscs = self.select_list.converted_exp_str

            #sscs = self.select_list.converted_str

        if self.where_condition is None:
            swc = str(None)
        else:
            #swc = self.where_condition.converted_exp_str
            swc = self.where_condition.where_condition_exp.evaluate()


        tmp_str_select_list = "[" + sscs + "]"
        tmp_str_where_condition = "[" + str(swc) + "]"

        name = "None" if self.name is None else self.name
        star = "*" if self.correlated else ""
        print pb, star + "TableNode", "(" + name + ")", self.table_name, "{" + self.table_alias + "}", tmp_str_select_list, tmp_str_where_condition


class TwoJoinNode(QueryPlanTreeBase):

    join_explicit = None
    join_type = None
    join_parameter = None
    join_condition = None
    left_composite = None
    right_composite = None
    project_func_list = None
    func_list = None
    func_alias = None


    left_child = None
    right_child = None
    parent = None

    def __init__(self):
        super(TwoJoinNode, self).__init__()


    def release_order_by(self):
        print >>sys.stderr,"WRONG"
        exit(29)

    def release_group_by(self):
        print >>sys.stderr,"WRONG"
        exit(29)

    def convert_to_binary_join_tree(self):
        print >>sys.stderr,"WRONG"
        exit(29)

# the get_pk function should be called after generating the index
    def get_pk(self):
        if self.join_condition is None:
            return None

        ret_exp_list = []
        tmp_list = []
        left_list = []
        right_list = []

        if self.join_explicit is True:
            __get_func_para__(self.join_condition.on_condition_exp,tmp_list)
#            print "self.on_condition_exp: ", self.join_condition.on_condition_exp.evaluate()
        elif isinstance(self.join_condition, str):
            tmp_list = []
        else:
            __get_func_para__(self.join_condition.where_condition_exp,tmp_list)
            # print "self.where_condition_exp: ", self.join_condition.where_condition_exp.evaluate()


        # print "tmp_list: ", map(lambda x: x.evaluate(), tmp_list)

        for i in range(0,len(tmp_list)):
            #new_exp = __trace_to_leaf__(self,tmp_list[i],True)
            if tmp_list[i].table_name == "LEFT":
                left_list.append(tmp_list[i])
            else:
                right_list.append(tmp_list[i])

        ret_exp_list.append(left_list)
        ret_exp_list.append(right_list)
        return ret_exp_list

    def adjust_index(self,exp_list,table_name):
        filter_name = ""
        if table_name in self.left_child.table_list or table_name == "LEFT":
            filter_name = "LEFT"
        else:
            filter_name = "RIGHT"

        for x in self.select_list.tmp_exp_list:
            if isinstance(x,YRawColExp):
                if x.table_name != filter_name:
                    continue
                index = x.column_name

                if filter_name == "LEFT":
                    old_exp = self.left_child.select_list.tmp_exp_list[index]
                else:
                    old_exp = self.right_child.select_list.tmp_exp_list[index]

                for exp in exp_list:
                    if exp.column_name == old_exp.column_name:
                        x.column_name = exp_list.index(exp)
                        break

        if self.where_condition is not None:
            col_list = []
            __get_func_para__(self.where_condition.where_condition_exp,col_list)
            for x in col_list:
                if x.table_name != filter_name:
                    continue
                index = x.column_name
                if filter_name == "LEFT":
                    old_exp = self.left_child.select_list.tmp_exp_list[index]
                else:
                    old_exp = self.right_child.select_list.tmp_exp_list[index]

                for exp in exp_list:
                    if exp.column_name == old_exp.column_name:
                            x.column_name = exp_list.index(exp)
                            break

    def set_composite(self,c_node,node):
        if self.left_child == node:
            self.left_composite = c_node
        else:
            self.right_composite = c_node

    def get_mapoutput(self,table_name):
            if table_name == "LEFT" or table_name in self.left_child.table_list \
                or table_name in self.left_child.table_alias_dict.values():
                return copy.deepcopy(self.left_child.select_list.tmp_exp_list)

            else:
                return copy.deepcopy(self.right_child.select_list.tmp_exp_list)

    def get_mapfilter(self,table_name):
            if table_name is None:
                return None
            if table_name in self.left_child.table_list:
                return self.left_child.where_condition
            else:
                return self.right_child.where_condition

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += "    "


        if self.select_list is None:
            sscs = str(None)
        else:
            sscs = self.select_list.converted_exp_str

        if self.where_condition is None:
            swc = str(None)
        else:
            #swc = self.where_condition.converted_exp_str
            swc = self.where_condition.where_condition_exp.evaluate()

        if self.join_explicit == True:
            #join_condition must be a FirstStepOnCondition
            if self.join_condition is None:
                oc = str(None)
            else:
                #oc = self.join_condition.converted_exp_str
                # oc = self.join_condition.join_condition_exp.evaluate()
                return
        else:
            oc = str(None)
            if self.join_condition is not None and not isinstance(self.join_condition, str) \
                and self.join_condition.where_condition_exp is not None:
                oc = "[Implicit]: " + self.join_condition.where_condition_exp.evaluate()

        name = "None" if self.name is None else self.name
        star = "*" if self.correlated else ""
        print pb, star + "TwoJoinNode", "(" + name + ")", "[" + sscs + "]", "[" + swc + "]", "[" + oc + "]"

        self.left_child.debug(level + 1)

        self.right_child.debug(level + 1)

#useless once we have TwoJoinNode
class MultipleJoinNode(QueryPlanTreeBase):

    join_explicit = None
    join_info = None
    children_list = None
    join_knn_parameter = None

    def __init__(self):
        super(MultipleJoinNode, self).__init__()


    def release_order_by(self):

        tmp_list = self.children_list
        self.children_list = []

        for a_child in tmp_list:
            self.children_list.append(a_child.release_order_by())

        return super(MultipleJoinNode,self).release_order_by()

    def release_group_by(self):

        tmp_list = self.children_list
        self.children_list = []

        for a_child in tmp_list:
            self.children_list.append(a_child.release_group_by())

        return super(MultipleJoinNode,self).release_group_by()

    def convert_to_binary_join_tree(self):

        #Step1: process children
        tmp_list = list(self.children_list)
        self.children_list = []

        for a_child in tmp_list:
            self.children_list.append(a_child.convert_to_binary_join_tree())

        #Step2: process myself
        if True:

            tmp_children_list = list(self.children_list)

            current_node = None

            tmp_index = -1

            for a_child in tmp_children_list:

                if current_node is None:

                    current_node = a_child

                else:

                    a_join_node = TwoJoinNode()

                    a_join_node.source = self
                    a_join_node.join_explicit = self.join_explicit

                    a_join_node.left_child = copy.deepcopy(current_node)
                    a_join_node.left_child.parent = a_join_node
                    a_join_node.right_child = copy.deepcopy(a_child)
                    a_join_node.right_child.parent = a_join_node

                    for x in current_node.table_list:
                        if x not in a_join_node.table_list:
                            a_join_node.table_list.append(x)
                    a_join_node.table_alias_dict = current_node.table_alias_dict


                    for x in a_child.table_alias_dict.keys():
                        if x not in a_join_node.table_alias_dict.keys():
                            a_join_node.table_alias_dict[x] = a_child.table_alias_dict[x]
                        else:
                            exit(29)


                    for x in a_child.table_list:
                        if x not in a_join_node.table_list:
                            a_join_node.table_list.append(x)

                    if self.join_explicit == True:

                        tmp_list_join_condition = self.join_info[0]
                        tmp_list_join_type = self.join_info[1]
                        tmp_list_join_parameter = self.join_info[2]

                        a_join_node.join_condition = tmp_list_join_condition[tmp_index]
                        a_join_node.join_type = tmp_list_join_type[tmp_index]
                        a_join_node.join_parameter = tmp_list_join_parameter[tmp_index]

                    current_node = a_join_node

                tmp_index += 1

            current_node.select_list = copy.deepcopy(self.select_list)
            current_node.where_condition = copy.deepcopy(self.where_condition)

            if self.join_explicit == False:
                current_node.join_condition = copy.deepcopy(self.where_condition)

            return current_node

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += "    "


        if self.select_list is None:
            sscs = str(None)
        else:
            sscs = self.select_list.converted_str


        if self.where_condition is None:
            swc = str(None)
        else:
            swc = self.where_condition.converted_str

        print pb, "MultipleJoinNode", "[" + sscs + "]", "[" + swc + "]"
        for a_child in self.children_list:
            a_child.debug(level + 1)

class CompositeNode(QueryPlanTreeBase):

    it_node_list = []
    jfc_node_list = []
    pk_dict = {}
    mapoutput = {}
    mapfilter = {}
    child_list = []
    composite = None
    parent = None
    dep = 0

    def __init__(self):
        super(QueryPlanTreeBase,self).__init__()

        self.pk_dict = {}
        self.it_node_list = []
        self.jfc_node_list = []
        self.mapoutput = {}
        self.mapfilter = {}
        self.child_list = []
        self.composite = None
        self.dep = 0
        self.parent = None

    def release_order_by(self):
        pass

    def release_group_by(self):
        pass

    def get_pk(self):
        pk_list = []
        for x in self.pk_dict.keys():
                for y in self.pk_dict[x]:
                    pk_list.append(y)
        return pk_list

    def get_mapoutput(self,table_name):
        return copy.deepcopy(self.maoutput_dict[table_name].tmp_exp_list)

    def adjust_index(self,exp_list,table_name):
        return



############################################################################################
############################################################################################
########################    LRBSelectNode    ###############################################
############################################################################################
############################################################################################



class LRBSelectNode:

    select_list = None
    where_condition = None
    from_list = None
    group_by_clause = None

    having_clause = None
    order_by_clause = None

    converted_from_list = None # a list of LRBSelectNodes

    def __init__(self):

        self.from_list = []

        pass


    def utility_convert_to_initial_plan_tree(self, a_input, i_am_the_tree):

        tn = None

        if a_input["type"] == 'BaseTable':

            #tn should be a simple tablescan
            tn = TableNode()
            tn.source = a_input
            tn.i_am_the_tree = i_am_the_tree

            if i_am_the_tree:
                tn.select_list = self.select_list
                tn.where_condition = self.where_condition
                tn.group_by_clause = self.group_by_clause
                tn.having_clause = self.having_clause
                tn.order_by_clause = self.order_by_clause

            tn.table_name = a_input["content"].upper()
            tn.table_alias = a_input["alias"].upper()

            if tn.table_alias == "":
                tn.table_list.append(tn.table_name)
            else:
                tn.table_list.append(tn.table_alias)
                tn.table_alias_dict[tn.table_alias] = tn.table_name


        elif a_input["type"] == 'SubQuery':

            #tn should have two nodes: a SP and its underlying child
            tn = SelectProjectNode()
            tn.source = a_input
            tn.i_am_the_tree = i_am_the_tree

            if i_am_the_tree:
                tn.select_list = self.select_list
                tn.where_condition = self.where_condition
                tn.group_by_clause = self.group_by_clause
                tn.having_clause = self.having_clause
                tn.order_by_clause = self.order_by_clause


            tn.child = a_input["content"].convert_to_initial_query_plan_tree()
            tn.table_alias = a_input["alias"]
            if tn.table_alias is not None:
                tn.table_alias = tn.table_alias.upper()


            if tn.table_alias is not None and tn.table_alias not in tn.table_list:
                tn.table_list.append(tn.table_alias)


##
##      construct the project list
##

        elif a_input["type"] == 'JoinClause':

            #tn should be a multiple Join
            tn = MultipleJoinNode()
            tn.source = a_input
            tn.i_am_the_tree = i_am_the_tree


            #Step0: setup basic information

            if i_am_the_tree:
                tn.select_list = self.select_list
                tn.where_condition = self.where_condition
                tn.group_by_clause = self.group_by_clause
                tn.having_clause = self.having_clause
                tn.order_by_clause = self.order_by_clause

            #Add new grammar: fill table_list of MultipleJoinNode
            for i in range(len(a_input['content'])):
                if a_input["content"][i]["type"] == "BaseTable" and a_input["content"][i]["content"].upper() not in tn.table_list:
                    table_name = a_input["content"][i]["content"].upper()
                    table_alias = a_input["content"][i]["alias"].upper()

                    if table_alias == "":
                        tn.table_list.append(table_name)
                    else:
                        tn.table_list.append(table_alias)
                        tn.table_alias_dict[table_alias] = table_name

            #Step1: setup children list
            tmp_child_list = []
            for a_sub_item in a_input["content"]:

                a_child = self.utility_convert_to_initial_plan_tree(a_sub_item, False)

                tmp_child_list.append(a_child)

            tn.children_list = list(tmp_child_list)

            #Step2: setup join condition

            tn.join_explicit = True
            tn.join_info = []
            tn.join_info.append(a_input["jc_on_condition"])
            tn.join_info.append(a_input["jc_jointype_list"])
            tn.join_info.append(a_input["KNN_num"])

        else:
            print >>sys.stderr,"\n\nERROR: UNKNOWN TYPE in utility_convert_to_initial_plan_tree \n\n"
            exit(29)

        return tn

    def convert_to_initial_query_plan_tree(self):

        final_node = None

        scfl = self.converted_from_list

        if len(scfl) == 1:
            a_scfl_item = scfl[0]

            final_node = self.utility_convert_to_initial_plan_tree(a_scfl_item, True)

        else:

            final_node = MultipleJoinNode()

            # Step0: setup basic information

            final_node.select_list = self.select_list
            final_node.where_condition = self.where_condition
            final_node.group_by_clause = self.group_by_clause
            final_node.having_clause = self.having_clause
            final_node.order_by_clause = self.order_by_clause

            # Step1: set up children
            tmp_list = []
            for a_scfl_item in scfl:

                result_item = self.utility_convert_to_initial_plan_tree(a_scfl_item, False)

                tmp_list.append(result_item)
                for x in result_item.table_alias_dict.keys():
                    if x not in final_node.table_alias_dict.keys():
                        final_node.table_alias_dict[x] = result_item.table_alias_dict[x]
                    else:
                        exit(29)

                for x in result_item.table_list:
                    if x not in final_node.table_list:
                        final_node.table_list.append(x)

            final_node.children_list = list(tmp_list)


            # Step 2: setup join condition
            final_node.join_explicit = False
            final_node.join_info = []
            final_node.join_info.append(self.where_condition)

        return final_node


    def debug_converted_from_list(self,level):
        pb = ""
        for i in range(level):
            pb += "    "


        for a_from_list in self.converted_from_list:
            mytype =  a_from_list["type"]
            print pb, mytype

            if mytype == 'BaseTable':
                print pb, a_from_list["content"], str(self.select_list), str(self.where_condition)
            elif mytype == 'SubQuery':
                a_from_list["content"].debug_converted_from_list(level + 1)
            elif mytype == 'JoinClause':
                for x in a_from_list["content"]:
                    xmytype = x["type"]
                    if xmytype == 'BaseTable':
                        print "->"
                        print pb, x["content"]
                    else:
                        print "->"
                        x["content"].debug_converted_from_list(level + 1)
            else:
                print "*********************ERROR*********************", mytype

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += " "


        print pb, "a SELECT:"
        print pb, "my select_list:", self.select_list
        print pb, "my where clause:", self.where_condition
        print pb, "my groupby clause:", self.group_by_clause

        print pb, "my from list:"
        for af in self.from_list:
            if isinstance(af, LRBSelectNode):
                print pb, "an item:"
                af.debug(level + 1)
            else:
                print pb, "an item:", af
                af.debug(level + 1)


    def utility_convert_from_list(self, atomic_input_list):

        #this ia utility function

        a_r_item = dict()

        if len(atomic_input_list) < 3:

            a_r_item["type"] = "BaseTable"
            a_r_item["source"] = atomic_input_list

            a_r_item["content"] = atomic_input_list[0].content
            if len(atomic_input_list) == 2:
                a_r_item["alias"] = atomic_input_list[1].content
            else:
                a_r_item["alias"] = ""

        else:

            a_r_item["type"] = "SubQuery"
            a_r_item["source"] = atomic_input_list

            t_sub_tree = None
            t_id = None
            for x in atomic_input_list:
                if isinstance(x, LRBSelectNode):
                    t_sub_tree = x

                else:
                    if x.tokenname.upper() == 'ID':
                        t_id = x.content

            a_r_item["content"] = t_sub_tree
            a_r_item["alias"] = t_id

        return a_r_item

    def process_from_list(self):

        final_from_list = []
        #remove the first one, it is the "from" keyword

    #------------Step 1: partition by COMMA---------------------------------

        tmp_scan_list = []
        # print "length of self.from_list: ", len(self.from_list)
        # map(lambda x: x.debug(1), self.from_list)
        for a_from_item in self.from_list[1:]:

            tmp_scan_list.append(a_from_item)

            if isinstance(a_from_item, LRBSTreeNode):
                if a_from_item.tokenname == 'COMMA':
                    final_from_list.append(tmp_scan_list[:-1])
                    tmp_scan_list = []

            else:
                # a_from_item is a subquery
                a_from_item.process_from_list()

        final_from_list.append(tmp_scan_list)
        # print "final_scan_list:"
        # map(lambda item: map(lambda item2: item2.debug(1), item), final_from_list)
        #        print final_from_list


    #------------Step 2: convert each item---------------------------------


        t_converted_from_list = []
        self.converted_from_list = t_converted_from_list
        # dict: source:xmlnode, content:content(tablename), type:BaseTable|Subquery|JoinClause, alias:alias

        for fa in final_from_list:


            #fa is an array
            #fa can only a base_relation, a join clause, or a subquery

            a_r_item = dict()

            #--------Case 1----------------------------------------------------------------------------
            if len(fa) < 3:
                #fa is a base_relation with alias or not
                # type:
                # source:
                # content:
                # alias:

                a_r_item["type"] = "BaseTable"
                a_r_item["source"] = fa

                #content is the table name
                a_r_item["content"] = fa[0].content
                if len(fa) == 2:
                    a_r_item["alias"] = fa[1].content
                else:
                    a_r_item["alias"] = ""

                t_converted_from_list.append(a_r_item)
                continue

            #--------Case 2----------------------------------------------------------------------------
            #now process fa
            hasjoin = False
            for x in fa:
                if (not isinstance(x, LRBSelectNode)) and x.content.upper() == "JOIN":
                    #fa is a join clause
                    hasjoin = True

            if not hasjoin:
                #fa must be a subquery

                a_r_item["type"] = "SubQuery"
                a_r_item["source"] = fa

                t_sub_tree = None
                t_id = None
                for x in fa:
                    if isinstance(x, LRBSelectNode):
                        t_sub_tree = x

                    else:
                        if x.tokenname.upper() == 'ID':
                            t_id = x.content
                #content is the LRBSelectNode
                a_r_item["content"] = t_sub_tree
                a_r_item["alias"] = t_id

                t_converted_from_list.append(a_r_item)

                continue

            #--------Case 3--------------------------------------------------------------------------
            #fa is join clause

            a_r_item["type"] = "JoinClause"
            a_r_item["source"] = fa
            # content is a list
            a_r_item["content"] = []
            a_r_item["alias"] = []
            a_r_item["jc_jointype_list"] = []
            a_r_item["jc_on_condition"] = []
            a_r_item["KNN_num"] = []


            in_on = False

            t_list = []
            for x in fa:
                t_list.append(x)


                if isinstance(x, LRBSelectNode):
                    continue

                if x.content.upper() == "JOIN":

                    #now I have met a sub_join_item

                    if not in_on:

                        #if we use "tableA KNN(k=5) join tableB"

                        if t_list[-2].content != ')':
                            t_atomic_list = t_list[:-3]

                            a_jointype = t_list[-3].content
                            a_final_item = self.utility_convert_from_list(t_atomic_list)

                            a_r_item["content"].append(a_final_item)
                            a_r_item["jc_jointype_list"].append(a_jointype)
                            a_r_item["KNN_num"].append(-1)

                            #reset
                            t_list = []
                        else:
                            t_atomic_list = t_list[:-6]
                            a_jointype = 'KNN'
                            a_final_item = self.utility_convert_from_list(t_atomic_list)

                            a_r_item["content"].append(a_final_item)
                            a_r_item["jc_jointype_list"].append(a_jointype)
                            a_r_item["KNN_num"].append(int(t_list[-3].content))
                            
                            #reset
                            t_list = []
                        continue

                    else:
                        #what we have so far is on_condition

                        t_atomic_list = t_list[:-3]

                        a_jointype = t_list[-3].content


                        #a_r_item["jc_on_condition"].append(t_atomic_list)

                        fsoc = FirstStepOnCondition(t_atomic_list)
                        a_r_item["jc_on_condition"].append(fsoc)

                        a_r_item["jc_jointype_list"].append(a_jointype)

                        in_on = False

                        #reset
                        t_list = []

                        continue

                if x.content.upper() == "ON":

                    #now I have met the final sub_join_item

                    t_atomic_list = t_list[:-1]

                    a_final_item = self.utility_convert_from_list(t_atomic_list)

                    a_r_item["content"].append(a_final_item)

                    in_on = True

                    #reset
                    t_list = []

            #after the for loop, t_list is the on_condition

            fsoc = FirstStepOnCondition(t_list)
            a_r_item["jc_on_condition"].append(fsoc)

#            a_r_item["jc_on_condition"].append(t_list)


            t_converted_from_list.append(a_r_item)


############################################################################################
############################################################################################
########################              ASTree    ############################################
############################################################################################
############################################################################################


class FirstStepSelectList:

    source = None
    converted_str = None

    realstructure = None


    tmp_exp_list = None
    converted_exp_str = None


    dict_exp_and_alias = None

    def utility_convert_select_list_to_exp_list(self, select_list):

        return_exp_list = []

        if select_list is None:
            return return_exp_list


        yet = YExpTool()

        for t_child in select_list.child_list:


            if t_child.tokenname == 'T_SELECT_COLUMN':

                a_exp_input_list = []

                my_as_alias = None

                tmp_yes_we_are_as = False

                for t_t_child in t_child.child_list:
                    a_token = {}
                    a_token["name"] = t_t_child.tokenname
                    a_token["content"] = t_t_child.content


                    tmp_okay = True

                    if tmp_yes_we_are_as == True:
                        #this is the ID following AS, so we get it and quit
                        tmp_okay = False
                        my_as_alias = a_token["content"]#.upper()
                        continue

                    if a_token["name"] == 'T_RESERVED' and a_token["content"].upper() == 'AS':
                        #this is as for alias
                        tmp_yes_we_are_as = True
                        tmp_okay = False

                    if tmp_okay == True:
                        a_exp_input_list.append(a_token)

                a_exp = yet.convert_token_list_to_exp_tree(a_exp_input_list)


                #now it is time to setup alias

                # case 1: explicit: a AS b
                if my_as_alias is not None:
                    self.dict_exp_and_alias[a_exp] = my_as_alias.upper()

                # case 2: implicit a, or a.b

                elif isinstance(a_exp, YRawColExp):
                    self.dict_exp_and_alias[a_exp] = a_exp.column_name


                # case 3: no alias

                else:
                    self.dict_exp_and_alias[a_exp] = None


                return_exp_list.append(a_exp)

            else:
                #must be comma
                pass

        return return_exp_list


    def utility_convert_select_list_to_str(self, select_list):

        if select_list is None:
            return str(select_list)

        result_str = ""

        for t_child in select_list.child_list:

            if t_child.tokenname == 'T_SELECT_COLUMN':

                tmp_str = ""
                for t_t_child in t_child.child_list:
                    tmp_str += t_t_child.content

                result_str += tmp_str


            elif t_child.tokenname == 'COMMA':
                result_str += " , "

        return result_str


    def utility_convert_exp_list_to_str(self, input_exp):

        if input_exp is None:
                return str(None)
        s = ""
        for x in input_exp:
            t_alias = str(self.dict_exp_and_alias[x])
            t_str = x.evaluate()
            s = s + "[" + t_str + "]:" + t_alias
            s = s + " , "
        return s[:-2]


    def __init__(self, input_select_list):

        self.source = input_select_list
        self.converted_str = self.utility_convert_select_list_to_str(self.source)

        self.dict_exp_and_alias = {}

        self.tmp_exp_list = self.utility_convert_select_list_to_exp_list(self.source)

        self.converted_exp_str = self.utility_convert_exp_list_to_str(self.tmp_exp_list)

        self.realstructure = None


class FirstStepOnCondition:

    source = None
    converted_str = None

    realstructure = None

    on_condition_exp = None
    converted_exp_str = None

    def utility_convert_on_condition_item_to_str(self, on_condition_item):
        is_and_or = False

        if on_condition_item.tokenname == 'T_COND_OR' or on_condition_item.tokenname == 'T_COND_AND':

            result_str = ""

            for a_child in on_condition_item.child_list:
                result_str += self.utility_convert_on_condition_item_to_str(a_child)
                result_str += " "

            return result_str

        else:

            if on_condition_item.tokenname == 'GTH':
                return ">"
            elif on_condition_item.tokenname == 'LTH':
                return "<"
            elif on_condition_item.tokenname == 'NOT_EQ':
                return "<>"
            else:
                return on_condition_item.content


    def utility_convert_on_condition_to_str(self, on_condition):

        if on_condition is None:
            return str(None)

        cl = on_condition

        if len(cl) == 1:
            return self.utility_convert_on_condition_item_to_str(cl[0])

        else:
            result_str = ""
            for a_item in cl:
                result_str += self.utility_convert_on_condition_item_to_str(a_item)
                result_str += ""
            return result_str



    def __init__(self, input_on_condition):
        self.source = input_on_condition
        self.realstructure = None

        self.converted_str = self.utility_convert_on_condition_to_str(self.source)

        #we here use FirstStepWhereCondition's methonds

        u = FirstStepWhereCondition(None)

        self.on_condition_exp = u.utility_convert_real_where_condition_to_exp(self.source)
        self.converted_exp_str = u.utility_convert_exp_list_to_str(self.on_condition_exp)


class FirstStepWhereCondition:

    source = None
    converted_str = None

    realstructure = None

    where_condition_exp = None

    converted_exp_str = None

    def utility_convert_where_condition_item_to_str(self, where_condition_item):
        is_and_or = False

        if where_condition_item.tokenname == 'T_COND_OR' or where_condition_item.tokenname == 'T_COND_AND':

            result_str = ""

            for a_child in where_condition_item.child_list:
                result_str += self.utility_convert_where_condition_item_to_str(a_child)
                result_str += " "

            return result_str

        else:

            if where_condition_item.tokenname == 'GTH':
                return ">"
            elif where_condition_item.tokenname == 'LTH':
                return "<"
            elif where_condition_item.tokenname == 'NOT_EQ':
                return "<>"
            elif where_condition_item.tokenname == "GEQ":
                return ">="
            elif where_condition_item.tokenname == "LEQ":
                return "<="
            else:
                return where_condition_item.content


    def utility_convert_where_condition_to_str(self, where_condition):
        if where_condition is None:
            return str(None)

        cl = where_condition.child_list[1:]

        if len(cl) == 1:
            return self.utility_convert_where_condition_item_to_str(cl[0])

        else:
            result_str = ""
            for a_item in cl:
                result_str += self.utility_convert_where_condition_item_to_str(a_item)
                result_str += " "
            return result_str


    def utility_convert_real_where_condition_to_exp(self, real_where_condition):

        global subqueries
        #todo: consider ()!!!!!!!!!!!!!!!!!!!!!!

        c = real_where_condition

        if len(c) == 1:
            #it must be and or or


            c = c[0]

            if c.tokenname != 'T_COND_OR' and c.tokenname != 'T_COND_AND':

                exit(29)

            func_name = None
            if c.tokenname == 'T_COND_OR':
                func_name = "OR"
            elif c.tokenname == 'T_COND_AND':
                func_name = 'AND'


            all_my_child_list = c.child_list
            my_first_child = all_my_child_list[0]

            if my_first_child.tokenname == 'T_COND_OR' or my_first_child.tokenname == 'T_COND_AND':
                #that means that all my children are all and or or.
                #what I should do is to return a func expr
                pl = []


                for a_child in all_my_child_list:
                    pl.append(self.utility_convert_real_where_condition_to_exp([a_child]))


                yfc = YFuncExp(func_name, pl)

                return yfc

            elif my_first_child.tokenname == 'T_RESERVED' and ((my_first_child.content.upper() == 'AND') or (my_first_child.content.upper() == 'OR')):
                # we must remove the first child
                return self.utility_convert_real_where_condition_to_exp(all_my_child_list[1:])

            else:

                return self.utility_convert_real_where_condition_to_exp(all_my_child_list)

        else:
            #two cases:
            #Case 1: an regular exp: a.f1 > b.f2
            #Case 2: three items: "(",  "T_COND_AND",  ")"
            #Case 3: five items: "(", "T_SELECT", ")", op, col
            #Case 4: ten items: "KNN_AVG_DISTANCE", "(", col, COMMA, col , ")", op, "(", "T_SELECT", ")"

            #we first handle case 2 before we call yet to process case 1

            if len(c) == 3:
                #maybe this is case 2

                if c[0].tokenname == "LPAREN" and c[2].tokenname == "RPAREN" and (c[1].tokenname == "T_COND_AND" or c[1].tokenname == "T_COND_OR"):
                    #must be case 2
                    return self.utility_convert_real_where_condition_to_exp([c[1]])



            if len(c) == 5 and (c[1].tokenname == "T_SELECT" or c[3].tokenname == "T_SELECT"):
                select_pos = None
                if c[0].tokenname == "LPAREN" and c[2].tokenname == "RPAREN" and c[1].tokenname == "T_SELECT":
                    select_pos = 1
                elif c[2].tokenname == "LPAREN" and c[4].tokenname == "RPAREN" and c[3].tokenname == "T_SELECT":
                    select_pos = 3

                if select_pos != None:
                    subqueries.append( build_plan_tree_from_a_select_node( c[select_pos] ) )
                    external_cols = []
                    external_col_tokennames = []
                    for col in subqueries[-1].dynamic_values.keys():
                        external_cols.append(",")
                        external_cols.append(col)
                        external_col_tokennames.append("COMMA")
                        external_col_tokennames.append("ID")

                    subq_tokennames = ["SUBQ", "LPAREN", "SUBQREF"] + external_col_tokennames + ["RPAREN"]
                    subq_contents = ["SUBQ", "(", len(subqueries)-1] + external_cols + [")"]
                    subq_nodes = [ LRBSTreeNode(0, 0, "", 0, 0, None) for i in range(len(subq_tokennames)) ]

                    def __setup_node__(node, tokenname, content):
                        node.tokenname = tokenname
                        node.content = content

                    map(lambda idx : __setup_node__(subq_nodes[idx], subq_tokennames[idx], subq_contents[idx]), range(len(subq_nodes)))
                    c[select_pos-1 : select_pos+2] = subq_nodes
            
            # 10 items: "KNN_AVG_DISTANCE", "(", col, COMMA, col , ")", op, "(", "T_SELECT", ")"
            if len(c) == 10:
                select_pos = 8
                subqueries.append( build_plan_tree_from_a_select_node( c[select_pos] ) )
                external_cols = []
                external_col_tokennames = []
                for col in subqueries[-1].dynamic_values.keys():
                    external_cols.append(",")
                    external_cols.append(col)
                    external_col_tokennames.append("COMMA")
                    external_col_tokennames.append("ID")

                subq_tokennames = ["SUBQ", "LPAREN", "SUBQREF"] + external_col_tokennames + ["RPAREN"]
                subq_contents = ["SUBQ", "(", len(subqueries)-1] + external_cols + [")"]
                subq_nodes = [ LRBSTreeNode(0, 0, "", 0, 0, None) for i in range(len(subq_tokennames)) ]

                def __setup_node__(node, tokenname, content):
                    node.tokenname = tokenname
                    node.content = content

                map(lambda idx : __setup_node__(subq_nodes[idx], subq_tokennames[idx], subq_contents[idx]), range(len(subq_nodes)))
                c[select_pos-1 : select_pos+2] = subq_nodes
                # c[0:6]


            #now it is time to handle case 1

            yet = YExpTool()

            a_exp_input_list = []

            for t_child in c:#.child_list:

                a_token = {}
                a_token["name"] = t_child.tokenname
                a_token["content"] = t_child.content

                a_exp_input_list.append(a_token)

            return yet.convert_token_list_to_exp_tree(a_exp_input_list)


    def utility_convert_where_condition_to_exp(self, where_condition):

        if where_condition is None:
            return None

        cl = where_condition.child_list[1:]

        return self.utility_convert_real_where_condition_to_exp(cl)


    def utility_convert_exp_list_to_str(self, input_exp):
        if input_exp is None:
            return None
        return input_exp.evaluate()

    def __init__(self, input_where_condition):
        self.source = input_where_condition
        self.realstructure = None

        self.converted_str = self.utility_convert_where_condition_to_str(self.source)

        self.where_condition_exp = self.utility_convert_where_condition_to_exp(self.source)

        self.converted_exp_str = self.utility_convert_exp_list_to_str(self.where_condition_exp)


class FirstStepGroupBy:

    source = None
    converted_str = None

    realstructure = None

    groupby_exp_list = None
    converted_exp_str = None


    def utility_convert_group_by_to_str(self, group_by_clause):

        if group_by_clause is None:
            return str(group_by_clause)

        result_str = ""
        for t_child in group_by_clause.child_list:

            result_str += t_child.content

            if t_child.tokenname == 'T_RESERVED':

                result_str += " "

        return result_str


    def utility_convert_group_by_to_exp_list(self, group_by_clause):
        if group_by_clause is None:
            return []

        first_group_by_list = group_by_clause.child_list[2:]

        real_group_by_list = []

        a_group_by_item = []
        for eachitem in first_group_by_list:

            #todo: we don't consider GROUP BY myfunc(a,b)!

            if eachitem.tokenname != 'COMMA':

                a_token = {}
                a_token["name"] = eachitem.tokenname
                a_token["content"] = eachitem.content

                a_group_by_item.append(a_token)

            else:
                new_one = []
                for x in a_group_by_item:
                    new_one.append(x)

                real_group_by_list.append(new_one)

                a_group_by_item = []

        real_group_by_list.append(a_group_by_item)

        return_exp_list = []

        yet = YExpTool()

        for a_item in real_group_by_list:
            return_exp_list.append(yet.convert_token_list_to_exp_tree(a_item))


        return return_exp_list


    def utility_convert_exp_list_to_str(self, input_exp):
        s = ""
        if input_exp is None:
                return s
        for x in input_exp:
            t_str = x.evaluate()
            s = s + "(" + t_str + ")"
            s = s + " , "
        return s[:-2]


    def __init__(self, input_group_by):
        self.source = input_group_by
        self.realstructure = None
        self.converted_str = self.utility_convert_group_by_to_str(self.source)


        self.groupby_exp_list = self.utility_convert_group_by_to_exp_list(self.source)
        self.converted_exp_str = self.utility_convert_exp_list_to_str(self.groupby_exp_list)



class FirstStepOrderBy:

    source = None
    converted_str = None
    converted_exp_str = None


    orderby_exp_list = None

    #Asc or Desc
    order_indicator_list = None


    def utility_convert_order_by_to_exp_list(self, order_by_clause):

        if order_by_clause is None:
            return []

        first_order_by_list = order_by_clause.child_list[2:]

        real_order_by_list = []

        a_order_by_item = []
        for eachitem in first_order_by_list:

            #todo: we don't consider ORDER BY myfunc(a,b)!

            if eachitem.tokenname != 'COMMA':

                a_token = {}
                a_token["name"] = eachitem.tokenname
                a_token["content"] = eachitem.content

                a_order_by_item.append(a_token)

            else:
                #we get an item in Order By clause (to be polished...)

                #now we copy a new one. But why?
                new_one = []
                for x in a_order_by_item:
                    new_one.append(x)

                real_order_by_list.append(new_one)

                a_order_by_item = []


        real_order_by_list.append(a_order_by_item)

        return_exp_list = []
        tmp_order_indicator_list = []

        yet = YExpTool()

        for a_order_by_item in real_order_by_list:

            #we must handle the order indicator: DESC or ASC
            a_order_indicator = None
            if a_order_by_item[-1]["name"] == 'T_RESERVED':
                a_order_indicator = a_order_by_item[-1]["content"].upper()
                a_final_item = a_order_by_item[:-1]
            else:
                #default 'ASC'
                a_order_indicator = 'ASC'
                a_final_item = a_order_by_item

            tmp_order_indicator_list.append(a_order_indicator)

            return_exp_list.append(yet.convert_token_list_to_exp_tree(a_final_item))


        self.order_indicator_list = tmp_order_indicator_list

        return return_exp_list

    #Add default constructor
    def __init__(self, input_order_by):
        self.source = input_order_by

        #self.converted_str = self.utility_convert_order_by_to_str(self.source)


        self.order_indicator_list = []
        self.orderby_exp_list = self.utility_convert_order_by_to_exp_list(self.source)



def  convert_a_select_tree(a_s_select_node):

    result = LRBSelectNode()

    if a_s_select_node.tokenname != 'T_SELECT':
        print >>sys.stderr,"ERROR, not T_SELECT\n"
        exit(29)


    for t_child in a_s_select_node.child_list:

        if t_child.tokenname == 'RESERVED':
            #this is a useless select keyword
            continue

        if t_child.tokenname == 'T_COLUMN_LIST':
            #result.select_list = t_child
            result.select_list = FirstStepSelectList(t_child)
            continue

        if t_child.tokenname == 'T_WHERE':
            #result.where_condition = t_child
            result.where_condition = FirstStepWhereCondition(t_child)
            continue

        if t_child.tokenname == 'T_GROUP_BY':
            #result.group_by_clause = t_child
            result.group_by_clause = FirstStepGroupBy(t_child)
            continue

        if t_child.tokenname == 'T_HAVING':
            result.having_clause= FirstStepWhereCondition(t_child)
            continue


        if t_child.tokenname == 'T_ORDER_BY_CLAUSE':
            result.order_by_clause = FirstStepOrderBy(t_child)
            continue

        if t_child.tokenname == 'T_LIMIT_CLAUSE':
            main.limit = int(t_child.child_list[1].content)



        if t_child.tokenname == 'T_FROM':

            tmp_list = []
            for t_t_child in t_child.child_list:

                if t_t_child.tokenname != 'T_SELECT':
                    tmp_list.append(t_t_child)
                else:
                    converted_select_node = convert_a_select_tree(t_t_child)
                    tmp_list.append(converted_select_node)

            result.from_list = tmp_list
            continue


    return result




class LRBSTreeNode:

    line_number = -1
    position_in_line = -1
    tokenname = ""
    childcount = -1
    tokentype = -100
    content = None

    child_list = None

    def __init__(self, a_line_number, a_position_in_line, a_tokenname, a_childcount, a_tokentype, a_content):
        self.line_number = a_line_number
        self.position_in_line = a_position_in_line
        self.tokenname = a_tokenname
        self.childcount = a_childcount
        self.tokentype = a_tokentype
        self.content = a_content

        self.child_list = []

    def append_a_child(self, a_child):
        self.child_list.append(a_child)

    def debug(self, level):

        pb = ""
        for i in range(level):
            pb += " "

        print pb, self.content, self.tokenname


        for a_child in self.child_list:

            a_child.debug(level + 1)

def processNode(node):

    current_node = None

    if node.nodeType == Node.ELEMENT_NODE:

        if node.nodeName == 'node':

            t_line =  node.attributes.get('line').value
            t_positioninline =  node.attributes.get('positioninline').value
            t_tokenname = node.attributes.get('tokenname').value
            t_childcount =  node.attributes.get('childcount').value
            t_tokentype =  node.attributes.get('tokentype').value

        for child in node.childNodes:

            if child.nodeName == 'content':
                t_content = child.childNodes[0].nodeValue

        #now we have all info of a node

        current_node = LRBSTreeNode(t_line, t_positioninline, t_tokenname, t_childcount, t_tokentype, t_content)
        #print t_content

        for child in node.childNodes:

            if child.nodeName != 'content':

                a_child_node = processNode(child)

                if a_child_node is not None:

                    current_node.append_a_child(a_child_node)



    return current_node



############################################################################################
############################################################################################
########################    TableSchema         ############################################
############################################################################################
############################################################################################

def column_unique_in_table(column_name,table_name):
    if table_name not in global_table_dict.keys():
        return False

    count =0
    for x in global_table_dict[table_name].column_list:
        if x.column_name == column_name:
            count = count +1

    if count ==1:
        return True
    else:
        return False

## input: column_name and table_name
## return: if the table exists and has a column named column_name, return true. otherwise false
def column_in_table(column_name,table_name):
    if table_name not in global_table_dict.keys():
        return False

    for x in global_table_dict[table_name].column_list:
        if x.column_name == column_name:
            return True
    return False


def lookup_a_table(input_table_name):
    global global_table_dict

    if input_table_name in global_table_dict.keys():
        return global_table_dict[input_table_name]

    return None

def lookup_a_column(input_column_name):
    global global_table_dict

    return_list = []

    for x in global_table_dict.keys():
        for ac in global_table_dict[x].column_list:
            if input_column_name == "*":
                tmp = copy.deepcopy(ac)
                return_list.append(tmp)
                continue

            if ac.column_name == input_column_name:
                tmp = copy.deepcopy(ac)
                return_list.append(tmp)

    return return_list

def get_the_select_node_from_a_file(filename):

    doc = minidom.parse(filename)

    node = doc.documentElement


    a_query_node = None

    for child in node.childNodes:
        if child.nodeName == 'node':
            a_query_node = processNode(child)
            break

    return a_query_node


#This function processes a T_SELECT node
def build_plan_tree_from_a_select_node(a_query_node):

    r = convert_a_select_tree(a_query_node)

    r.process_from_list()

    t0 = r.convert_to_initial_query_plan_tree()

    t1 = t0.release_order_by()

    t2 = t1.release_group_by()

    t3 = t2.convert_to_binary_join_tree()

    process_the_plan_tree(t3)

    return t3

def debug_global_tables():

    global global_table_dict

    for x in global_table_dict.keys():
        print x
        print global_table_dict[x].column_name_list
        for y in global_table_dict[x].column_list:
            print y.column_name, y.column_type
        print "-----------------"


    tl = lookup_a_column("f2")
    for t in tl:
        print t.table_schema.table_name

##########################################################
#
#     Added by YY
#
###########################################################

def __check_column__(exp,table_list,table_alias_dict):

    if isinstance(exp,YRawColExp):
        if exp.table_name != "":
            if exp.table_name not in table_list and exp.table_name not in table_alias_dict.keys():
                return -1

            elif exp.column_name == '*':
                return 0
            else:
                tmp_name = None
                if exp.table_name in table_alias_dict.keys():
                    tmp_name = table_alias_dict[exp.table_name]
                else:
                    tmp_name = exp.table_name

                if column_unique_in_table(exp.column_name,tmp_name) is False:
                    return -1


        elif exp.column_name == '*':
            return 0
        else:
            count = 0

            tmp_name = None
            table_name = None
            for x in table_list:
                if x in table_alias_dict.keys():
                    tmp_name = table_alias_dict[x]
                else:
                    tmp_name = x
                if column_in_table(exp.column_name,tmp_name):
                    table_name = tmp_name
                    count = count +1

            if count !=1:
                return -1

            if column_unique_in_table(exp.column_name,table_name) is False:
                return -1

    else:
            return -1


def __check_func_para__(exp,table_list,table_alias_dict):
    res = 0
    func_dict = {                                                                   \
##
## the key is function name and for each function, there are three parameters:
##      1. number of parameters: 0 means any length that is greater than 0
##      2. type of input parameters, this is a list
##      3. type of return value, this is a list
##
            "SUM":[1,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],          \
            "COUNT":[1,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],        \
            "COUNT_DISTINCT":[1,["INTEGER","DECIMAL","TEXT","DATE"],["INTEGER"]],   \
            "AVG":[1,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],          \
            "MAX":[1,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],          \
            "MIN":[1,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],          \
            "PLUS":[2,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],         \
            "MINUS":[2,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],        \
            "MULTIPLY":[2,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],     \
            "DIVIDE":[2,["INTEGER","DECIMAL"],["INTEGER","DECIMAL"]],       \
            "AND":[0,["BOOLEAN"],["BOOLEAN"]],                              \
            "OR":[0,["BOOLEAN"],["BOOLEAN"]],                               \
            "GTH":[2,["INTEGER","DECIMAL","DATE","TEXT"],["BOOLEAN"]],             \
            "LTH":[2,["INTEGER","DECIMAL","DATE","TEXT"],["BOOLEAN"]],             \
            "EQ":[2,["INTEGER","DECIMAL","TEXT","DATE","VECTOR"],["BOOLEAN"]],               \
            "LEQ":[2,["INTEGER","DECIMAL","DATE","TEXT"],["BOOLEAN"]],             \
            "GEQ":[2,["INTEGER","DECIMAL","DATE","TEXT"],["BOOLEAN"]],             \
            "NOT_EQ":[2,["INTEGER","DECIMAL","DATE","TEXT"],["BOOLEAN"]],                 \
            "IS":[2,["INTEGER","DECIMAL","TEXT","DATE"],["BOOLEAN"]], \
            "SUBQ":[0,["INTEGER","DECIMAL", "DATE", "TEXT"],["DECIMAL", "INTEGER", "DATE", "TEXT"]], \
            "IN":[2,["TEXT", "DATE"],["BOOLEAN"]], \
            "LIST":[0,["TEXT", "DATE"],["TEXT", "DATE"]], \
            "LIKE":[2,["TEXT"],["BOOLEAN"]], \
            # add new grammar
            "DISTANCE":[2,["PATH","VECTOR"],["DECIMAL"]] ,            \
            "FEATURE_DISTANCE":[2,["VECTOR"],["DECIMAL"]] ,            \
            "EXTRACTION":[1,["PATH"],["VECTOR"]] ,                      \
            "VIDEO_FEATURE_EXTRACTION":[1,["PATH"],["VECTOR"]],      \
            "KNN":[2,["VECTOR", "PATH"],["DECIMAL"]],      \
            "OUTLIER":[1,["VECTOR"],["DECIMAL"]],            \
            "VIDEO_SIMILARITY":[2,["INTEGER","DECIMAL","VECTOR"],["INTEGER","DECIMAL"]],          \
            "OUTLIER_LINE":[1,["VECTOR"],["DECIMAL"]],            \
            "OUTLIER_SCORE":[1,["DECIMAL"],["DECIMAL"]],        \
            "KNN_AVG_DISTANCE":[2,["VECTOR"],["DECIMAL"]],        \
            "VIDEO_EXTRACTION":[1,["PATH"],["VECTOR"]]
    }

    if isinstance(exp,YFuncExp):
        if exp.func_name not in func_dict.keys():
            return -1

        func_para_len = func_dict[exp.func_name][0]
        if func_para_len == 0 and len(exp.parameter_list) == 0:
            return -1

        # VIDEO_SIMILARITY have one or two parameters
        # e.g.  VIDEO_SIMILARITY(VIDEO_EXTRACTION(path"/home/szr/video.mp4"), d_feature)
        # e.g.  VIDEO_SIMILARITY(DISTANCE(s_feature, d_feature))
        if func_para_len !=0 and func_para_len != len(exp.parameter_list) and exp.func_name != "VIDEO_SIMILARITY":
            return -1

        check_type = None

        for para in exp.parameter_list:
            if isinstance(para,YRawColExp):
                res = __check_column__(para,table_list,table_alias_dict)
                if res == -1 :
                    return res

                if para.column_name == "*":
                    if exp.func_name == "COUNT" :
                        continue
                    else:
                        return -1

                column_type = None
                tmp_column = lookup_a_column(para.column_name)
                for tmp in tmp_column:
                    if tmp.table_schema.table_name in table_list :
                        column_type = tmp.table_schema.get_column_type_by_name(para.column_name)
                        break
                    if tmp.table_schema.table_name in table_alias_dict.values():
                        column_type = tmp.table_schema.get_column_type_by_name(para.column_name)
                        break
                if column_type is not None:
                    if column_type not in func_dict[exp.func_name.upper()][1]:
                        return -1

                    if check_type is None or exp.func_name == "SUBQ":
                        check_type = column_type

                    else:
                        if check_type  in ["INTEGER","DECIMAL"] and column_type  in ["INTEGER","DECIMAL"]:
                            continue

                        elif check_type in ["DATE","TEXT"] and column_type in ["DATE","TEXT"]:
                            continue

                        elif check_type in ["PATH"] and column_type in ["VECTOR"]:
                            continue

                        elif check_type != column_type:
                            return -1
                else:
                    return -1

            elif isinstance(para,YFuncExp):
                res = __check_func_para__(para,table_list,table_alias_dict)
                if res == -1 :
                    return -1

                return_type = func_dict[para.func_name.upper()][2]
                if para.func_name == "SUBQ" and exp.func_name == "IN" and check_type in return_type:
                    return 0
                if para.func_name == "LIST" and exp.func_name == "LIKE" and check_type in return_type:
                    return 0


                for tmp in return_type:
                    if tmp not in func_dict[exp.func_name.upper()][1]:
                        return -1

                if check_type is None:
                    if len(return_type) >1:
                        check_type = "DECIMAL"
                    else:
                        check_type = return_type[0]

                else:
                    if para.func_name == "LIST" and check_type in return_type:
                        return 0

                    if len(return_type) >1:
                        if check_type not in ["INTEGER","DECIMAL"]:
                            return -1
                    else:
                        if check_type != return_type[0]:
                            return -1

            else:
                if exp.func_name == "LIST" or para.ref_col is not None:
                    try:
                        column_type
                    except NameError:
                        column_type = para.cons_type
                        continue

                if check_type is None:
                    check_type = para.cons_type
                else:
                    if para.cons_type == "NULL":
                        continue

                    if check_type in ["INTEGER","DECIMAL"] and para.cons_type in ["INTEGER","DECIMAL"]:
                        continue

                    elif check_type in ["DATE","TEXT"] and column_type in ["DATE","TEXT"]:
                        continue

                    # if check_type != para.cons_type:
                    #     return -1

    else:
        res = -1

    return res


def __schema_select_list__(select_list,table_list,table_alias_dict):
    res = 0
    select_func_list = ["SUM","AVG","COUNT","MAX","MIN","PLUS","MINUS","DIVIDE","MULTIPLY","COUNT_DISTINCT","DISTANCE","VIDEO_SIMILARITY","OUTLIER_LINE","OUTLIER_SCORE"]
    if select_list is None:
        return res

    for x in select_list.dict_exp_and_alias.keys():
        if isinstance(x,YRawColExp):
            res = __check_column__(x,table_list,table_alias_dict)
            if res == -1:
                return -1

        elif isinstance(x, YFuncExp):
            if x.func_name.upper() not in select_func_list:
                return -1

            res = __check_func_para__(x,table_list,table_alias_dict)
            if res == -1:
                return -1
        else:
            continue

    return res

## this function is to check the grammar of the func exp in the groupby  select_list

def __groupby_func_check__(exp,gb_list,table_list,table_alias_dict):


    res = 0

    if isinstance(exp,YFuncExp) is not True:
        return 0

    res = __check_func_para__(exp,table_list,table_alias_dict)
    if res == -1:
        return -1

    if exp.func_name in agg_func_list:
        return 0

    for tmp in exp.parameter_list:
        if isinstance(tmp,YRawColExp):
            tmp_bool = False
            for x in gb_list.groupby_exp_list:
                if isinstance(x,YRawColExp):
                    if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                        tmp_bool = True
                        break
            if tmp_bool is False:
                return -1

        elif isinstance(tmp,YFuncExp):
            res = __groupby_func_check__(tmp,gb_list,table_list,table_alias_dict)
            if res == -1:
                return -1

        else:
            continue


##
## the select_list shouldnot have any grammar errors.
##
def __schema_groupby__(groupby_list,select_list,table_list,table_alias_dict):


    res = 0
    if groupby_list is None:
        return 0

    if select_list is None:
        return -1

    exp_dict = select_list.dict_exp_and_alias

    for exp in groupby_list.groupby_exp_list :
        if isinstance(exp,YRawColExp):
            res = __check_column__(exp,table_list,table_alias_dict)
            if res == -1:
                return -1

        elif isinstance(exp,YFuncExp):

            res = __check_func_para__(exp,table_list,table_alias_dict)
            if res == -1:
                return -1

        else:
            continue

    for exp in exp_dict.keys():
        if isinstance(exp,YRawColExp):
            tmp_bool = False
            for tmp in groupby_list.groupby_exp_list:
                if isinstance(tmp,YRawColExp):
                    if tmp.column_name == exp.column_name:
                        tmp_bool = True
                        break

            if tmp_bool is False:
                return -1

        elif isinstance(exp,YFuncExp):
            res = __groupby_func_check__(exp,groupby_list,table_list,table_alias_dict)
            if res == -1:
                return -1

        else:
            continue

def __schema_having__(having_exp,groupby_list,table_list,table_alias_dict):

    res = 0

    if isinstance(having_exp,YFuncExp) is False:
        print >>sys.stderr,"check schema for having_clause: no having clause"
        exit(29)

    res = __check_func_para__(having_exp,table_list,table_alias_dict)
    if res == -1:
        return -1

    if having_exp.func_name in ["AND","OR"]:
        for x in having_exp.parameter_list:
            res = __schema_having__(x,groupby_list,table_list,table_alias_dict)
            if res == -1:
                return -1
    elif having_exp.func_name in agg_func_list:
        return 0

    else:
        res = __groupby_func_check__(having_exp,groupby_list,table_list,table_alias_dict)
        if res == -1:
            return -1

    return res

def __schema_where__(where,table_list,table_alias_dict):
    res = 0
    func_list = ["AND","OR","EQ", "GTH", "LTH", "NOT_EQ", "GEQ","LEQ","LIKE","IS", "IN","DISTANCE"]

    if where is None:
        return res

    exp = where.where_condition_exp
    if isinstance(exp,YFuncExp):
        if exp.func_name not in func_list:
            return -1

        res = __check_func_para__(exp,table_list,table_alias_dict)

    elif isinstance(exp,YRawColExp):
        res = __check_column__(exp,table_list,table_alias_dict)
        if res == -1:
            return -1

        tmp_name = None
        for x in table_list:
            if column_in_table(exp.column_name,x) is True:
                tmp_name = x
                break
        if tmp_name is None:
            for x in table_list.values():
                if column_in_table(exp.column_name,x) is True:
                    tmp_name = x
                    break

        if tmp_name is None:
            print >>sys.stderr,"Grammar Error."
            exit(39)

        column_type = global_table_dict[tmp_name].get_column_type_by_name(exp.column_name)

        if column_type.upper() is not "BOOLEAN":
            return -1


    return res


def __schema_join__(join_cond,table_list,table_alias_dict):
    res = 0
    func_list = ["AND","OR","EQ", "GTH", "LTH", "NOT_EQ", "GEQ","LEQ","LIKE","IS"]

    if join_cond is None:
        return res

    exp = join_cond.on_condition_exp
    if isinstance(exp,YFuncExp):
        if exp.func_name.upper() not in func_list:
            return -1

        res = __check_func_para__(exp,table_list,table_alias_dict)
    else:
        res = -1

    return res

def __schema_orderby__(orderby_exp_list,select_list_alias,table_list,table_alias_dict):

    res = 0

    for exp in orderby_exp_list:
        if isinstance(exp,YRawColExp):
            count = 0
            for x in select_list_alias.keys():
                if select_list_alias[x] == exp.column_name:
                    count = count +1
                    continue

                elif isinstance(x,YRawColExp):
                    if x.column_name == exp.column_name:
                        count = count +1
                        continue

            if count == 1:
                   continue
            elif count >1:
                return -1

            else:
                res = __check_column__(exp,table_list,table_alias_dict)
                if res ==-1:
                    return -1


        elif isinstance(exp,YFuncExp):
            if exp.func_name in agg_func_list:
                return -1
            res = __check_func_para__(exp,table_list,table_alias_dict)
            if res == -1:
                return -1

    return res

def check_schema(tree):
    res = 0

    if isinstance(tree,TableNode):

        if lookup_a_table(tree.table_name) is None:
            print >>sys.stderr,"\tGrammar error: the table doesn't exit",tree.table_name
            exit(39)

        res = __schema_select_list__(tree.select_list,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error: select list error",tree.select_list.converted_str
            exit(39)

        res = __schema_where__(tree.where_condition,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error: where condition error",tree.where_condition.converted_str
            exit(39)

    elif isinstance(tree,OrderByNode):

        res = __schema_orderby__(tree.order_by_clause.orderby_exp_list,tree.child.select_list.dict_exp_and_alias,tree.table_list,tree.table_alias_dict)

        if res == -1:
            print >>sys.stderr,"Grammar error: Order_by_exp error"
            exit(39)

        res = check_schema(tree.child)
        if res == 1:
            return -1

    elif isinstance(tree,TwoJoinNode):
        if tree.join_explicit == True:
            res = __schema_join__(tree.join_condition,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:join condition error",tree.join_condition.converted_str
            exit(39)

        res = __schema_where__(tree.where_condition,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:where condition error",tree.where_condition.converted_str
            exit(39)

        res = __schema_select_list__(tree.select_list,tree.table_list,tree.table_alias_dict)
        if res ==-1:
            print >>sys.stderr,"\tGrammar error:select list error",tree.select_list.converted_str
            exit(39)

        res = check_schema(tree.left_child)
        if res == -1:
            exit(39)

        res = check_schema(tree.right_child)
        if res == -1:
            exit(39)

    elif isinstance(tree,GroupByNode):
        res = __schema_select_list__(tree.select_list,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:select_list error",tree.select_list.converted_str
            exit(39)

        res = __schema_where__(tree.where_condition,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:where condition error",tree.where_condition.converted_str
            exit(39)

        res = __schema_groupby__(tree.group_by_clause,tree.select_list,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:groupby clause error"
            exit(39)

        if tree.having_clause is not None:
            res = __schema_having__(tree.having_clause.where_condition_exp,tree.group_by_clause,tree.table_list,tree.table_alias_dict)
            if res == -1:
                print >>sys.stderr,"\tGrammar error:having clause error"
                exit(39)

        res = check_schema(tree.child)

    elif isinstance(tree,SelectProjectNode):

        res = __schema_select_list__(tree.select_list,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:select_list error",tree.select_list.converted_str
            exit(39)

        res = __schema_where__(tree.where_condition,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:where condition error",tree.where_condition.converted_str
            exit(39)

        res = __schema_groupby__(tree.group_by_clause,tree.select_list,tree.table_list,tree.table_alias_dict)
        if res == -1:
            print >>sys.stderr,"\tGrammar error:groupby clause error"
            exit(39)

        res = check_schema(tree.child)
        if res == -1:
            exit(39)

    else:
        res = -1
        exit(39)

    return res

def __remove_para__(para):

    exp = para.func_obj
    new_list = []

    if isinstance(exp,YFuncExp) is False or exp == para:
        return

    for x in exp.parameter_list:
        if x == para:
            continue
    #               tmp_cons = YConsExp(True,"BOOLEAN")
    #               exp.parameter_list.append(tmp_cons)
        else:
            new_list.append(x)

    exp.set_para_list(new_list)


def __gen_join_key__(exp,key_bool):

    return_exp = None
    func_list = ["AND","OR"]
    cmp_list = ["LTH","GTH"]

    if not isinstance(exp,YFuncExp):
        return None

    if exp.func_name in func_list:
        exp_list = []
        if exp.func_name == "OR":
            return None

        for x in exp.parameter_list:
            if not isinstance(x,YFuncExp):
                print >>sys.stderr,"Internal error: __gen_join_key__"
                exit(29)

            tmp_exp = __gen_join_key__(x,True)

            if tmp_exp is not None:
                exp_list.append(tmp_exp)

        if len(exp_list) == 0:
            return None
        # elif len(exp_list) == 1:
        else:
            return_exp = copy.deepcopy(exp_list[0])
            __remove_para__(exp_list[0])
            return return_exp

        # else:
        #     for x in exp_list:
        #         __remove_para__(x)
        #     return_exp = YFuncExp("AND",exp_list)
        #     return return_exp

    elif exp.func_name in cmp_list:
        join_func = exp.parameter_list[0]
        para1 = join_func.parameter_list[0]
        para2 = join_func.parameter_list[1]
        if isinstance(para1,YRawColExp) and isinstance(para2,YRawColExp):
            if para1.table_name != para2.table_name:
                return exp
            
            return None

    else:
        if exp.func_name != "EQ":
            return  None

        para1 = exp.parameter_list[0]
        para2 = exp.parameter_list[1]

        if isinstance(para1,YRawColExp) and isinstance(para2,YRawColExp):
            if para1.table_name != para2.table_name:
                return exp

        return None

#the resulst value is either an YFuncExp or None. Be careful
#It will remove the filtered exp from the func parameter_list

def  __boolean_exp_filter__(exp,table_list,table_alias_dict,remove_bool):
    return_exp = None
    func_list = ["AND","OR"]

    if isinstance(exp.parameter_list[0], YFuncExp) and \
        exp.parameter_list[0].func_name in ["DISTANCE"]:
        exp_bool = __boolean_exp_filter__(exp.parameter_list[0],table_list,table_alias_dict,remove_bool)
        return  exp_bool
    if isinstance(exp,YFuncExp):
        if exp.func_name == "IS":
            return  None

        elif exp.func_name in func_list:
            exp_list = []

            tmp_bool = True
            for tmp in exp.parameter_list:
                if isinstance(tmp,YFuncExp):
                    if exp.func_name == "OR":
                        tmp_exp = __boolean_exp_filter__(tmp,table_list,table_alias_dict,False)
                    else:
                        tmp_exp = __boolean_exp_filter__(tmp,table_list,table_alias_dict,remove_bool)

                    if exp.func_name == "OR" and tmp_exp is None:
                        tmp_bool = False

                    if tmp_exp is not None:
                        exp_list.append(tmp_exp)

                else:
                    print >>sys.stderr,"Internal error:__boolean_exp_filter__"
                    exit(29)

            if tmp_bool == False:
                return None

            if len(exp_list) == 0:
                return None

            elif len(exp_list) == 1:
                return_exp = copy.deepcopy(exp_list[0])
                if remove_bool is True:
                    __remove_para__(exp_list[0])
                return return_exp

            else:
                if remove_bool is True:
                    for x in exp_list:
                        __remove_para__(x)
                return_exp = YFuncExp(exp.func_name,exp_list)

                return return_exp

        else:
            exp_bool = True
            for tmp in exp.parameter_list:
                tmp_bool = False
                if isinstance(tmp,YRawColExp):
                    for x in table_list:
                        if x != tmp.table_name:
                            continue
                        if column_in_table(tmp.column_name,x):
                            tmp_bool = True
                            break

                    for x in table_alias_dict.keys():
                        if x != tmp.table_name:
                            continue
                        if column_in_table(tmp.column_name,table_alias_dict[x]):
                            tmp_bool = True
                            break

                elif isinstance(tmp,YConsExp):
                    tmp_bool = True

                else:
                    new_exp = __boolean_exp_filter__(tmp,table_list,table_alias_dict,False)
                    if new_exp is not None:
                        tmp_bool = True

                exp_bool = tmp_bool and exp_bool

            if exp_bool is True:
                return_exp = copy.deepcopy(exp)
                if remove_bool is True:
                    __remove_para__(exp)
                return return_exp
            else:
                return None

    else:
        print >>sys.stderr,"Internal error:__boolean_exp_filter__"
        exit(29)

### filter the groupby where expression. return the exp that can be pushed down to the child.
### also remove it from the original exp

def __groupby_where_filter__(exp):
    func_list = ["AND","OR"]

    if not isinstance(exp,YFuncExp):
        print >>sys.stderr,"Internal error:__groupby_where_filter__"
        exit(29)

    if exp.func_name in func_list:
        exp_list = []
        for x in exp.parameter_list:
            tmp_exp = __groupby_where_filter__(x)
            if tmp_exp is not None:
                exp_list.append(tmp_exp)
        if len(exp_list) == 0:
            return None
        elif len(exp_list) == 1:
            __remove_para__(exp_list[0])
            return exp_list[0]
        else:
            for x in exp_list:
                __remove_para__(x)
            ret_exp = YFuncExp(exp.func_name,exp_list)
            return ret_exp

    else:
        if exp.has_groupby_func() is True:
            return None
        else:
            return exp

def predicate_pushdown(tree):

    if isinstance(tree,TableNode):
        return

    elif isinstance(tree,OrderByNode):
            predicate_pushdown(tree.child)

    elif isinstance(tree,GroupByNode):

        if tree.where_condition is  not None:

            new_where = __groupby_where_filter__(tree.where_condition.where_condition_exp)
#### the where condition of the groupby node is pushed down by its parent.
### only the exp without the agg function can be pushed to its child
            if new_where is not None:
                if tree.child.where_condition is not None:
                    old_exp = tree.child.where_condition.where_condition_exp
                    para_list = []
                    para_list.append(old_exp)
                    para_list.append(new_where)
                    new_exp = YFuncExp("AND",para_list)
                    tree.child.where_condition.where_condition_exp = copy.deepcopy(new_exp)
                else:
                    tree.child.where_condition = FirstStepWhereCondition(None)
                    tree.child.where_condition.where_condition_exp = copy.deepcopy(new_where)

### check if all the where condition has been pushed down to the child
            if tree.where_condition.where_condition_exp.has_groupby_func() is False:
                tree.where_condition = None

        if tree.having_clause is not None:
            if tree.where_condition is None:
                tree.where_condition = FirstStepWhereCondition(None)
                tree.where_condition.where_condition_exp = copy.deepcopy(tree.having_clause.where_condition_exp)
            else:
                para_list = []
                para_list.append(tree.where_condition.where_condition_exp)
                para_list.append(tree.having_clause.where_condition_exp)
                tree.where_condition.where_condition_exp = YFuncExp("AND",para_list)

        predicate_pushdown(tree.child)

    elif isinstance(tree,SelectProjectNode):

        new_exp = None

        if tree.where_condition is not None:
# the where_condition of the SP node will not be changed
            exp = copy.deepcopy(tree.where_condition.where_condition_exp)

            # if child is groupbyNode and whereExp col use child's agg_func result
            if exp is not None and isinstance(tree.child, GroupByNode) and exp.func_name not in ["AND", "OR"]:
                col_list = []
                __get_func_para__(exp,col_list)
                select_dict = tree.child.select_list.dict_exp_and_alias
                for tmp in col_list:
                    tmp_bool = False
                    for x in select_dict.keys():
                        if tmp.column_name == select_dict[x] and x.func_name in agg_func_list:
                            tmp_bool = True
                            tree.table_name = tree.table_list[0]
                if tmp_bool == True:
                    predicate_pushdown(tree.child)

            if exp is not None and tmp_bool == False:
##before pushdown change the column name and the table name to avoid grammar error

                col_list = []
                __get_func_para__(exp,col_list)
                select_dict = tree.child.select_list.dict_exp_and_alias

                for tmp in col_list:
                    tmp_bool = False
                    for x in select_dict.keys():
                        if tmp.column_name == select_dict[x]:
                            tmp_bool = True
                            tmp.table_name = ""
                            if isinstance(x,YRawColExp):
                                tmp.column_name = x.column_name
                                tmp.table_name = x.table_name

                            else:
#### fix me here:select * from (select (f1+f2) a from t1) x where x.a >1;
                                func_obj = tmp.func_obj
                                new_para_list = []
                                for cur_para in func_obj.parameter_list:
                                    if not isinstance(cur_para,YRawColExp):
                                        new_para_list.append(cur_para)
                                        continue

                                    if cur_para.column_name == tmp.column_name:
                                        new_para = copy.deepcopy(x)
                                        new_para_list.append(new_para)
                                    else:
                                        new_para_list.append(cur_para)

                                func_obj.set_para_list(new_para_list)

                            break

                        if isinstance(x,YRawColExp):
                            if tmp.column_name == x.column_name:
                                tmp_bool = True
                                tmp.table_name = x.table_name
                                break

                        elif isinstance(x,YFuncExp):
                            if tmp.column_name == select_dict[x]:
                                tmp_bool = True
                                tmp.table_name = ""
                                break

                    if tmp_bool is False:
                        print >>sys.stderr,"project predicate pushdown:This shouldn't happen",tmp.column_name,tree.table_list,tree.table_alias_dict,select_dict.values()
                        exit(29)


                child_exp = __boolean_exp_filter__(exp,tree.in_table_list,tree.in_table_alias_dict,True)

                if child_exp is not None:
                    if tree.child.where_condition is None:
                        tree.child.where_condition = FirstStepWhereCondition(None)
                        tree.child.where_condition.where_condition_exp = copy.deepcopy(child_exp)

                    else:
                        new_exp = copy.deepcopy(child_exp)
                        para_list = []
                        para_list.append(tree.child.where_condition.where_condition_exp)
                        para_list.append(new_exp)
                        tree.child.where_condition.where_condition_exp = YFuncExp("AND",para_list)
                tree.where_condition = None
                predicate_pushdown(tree.child)

    elif isinstance(tree,TwoJoinNode):

        if tree.where_condition is not None:
            exp = tree.where_condition.where_condition_exp

####generating join key expression

            left_exp =__boolean_exp_filter__(exp, tree.left_child.table_list, tree.left_child.table_alias_dict, True)
            right_exp =__boolean_exp_filter__(exp, tree.right_child.table_list, tree.right_child.table_alias_dict, True)

            if left_exp is not None:
                if tree.left_child.where_condition is None:
                    tree.left_child.where_condition = FirstStepWhereCondition(None)
                tree.left_child.where_condition.where_condition_exp = copy.deepcopy(left_exp)

            if right_exp is not None:
                if tree.right_child.where_condition is None:
                    tree.right_child.where_condition = FirstStepWhereCondition(None)
                tree.right_child.where_condition.where_condition_exp = copy.deepcopy(right_exp)

            if tree.join_explicit is False:
                join_exp = __gen_join_key__(exp,True)
                if join_exp is None:
                    tree.join_condition = "cartesianProduct"
                    tree.where_condition = None
                elif exp.compare(join_exp):
                    tree.where_condition = None
                if join_exp is not None:
                    if tree.join_condition is None:
                        tree.join_condition = FirstStepWhereCondition(None)
                    tree.join_condition.where_condition_exp = copy.deepcopy(join_exp)

            col_list = []

            __get_func_para__(exp,col_list)
            if len(col_list) == 0:
                tree.where_condition = None

        predicate_pushdown(tree.left_child)
        predicate_pushdown(tree.right_child)

    else:
        return


def isDistanceTwoCol(exp):
    if isinstance(exp, YFuncExp) and exp.func_name == "DISTANCE":
        if isinstance(exp.parameter_list[1], YRawColExp):
            return True
    return False

def projectFuncIndex(exp, projectList):
    for i in range(0, len(projectList)):
        if exp.compare(projectList[i]):
            return i
    return -1

#  process functions in select and where
#  that need to generate a new column 

#  e.g. select distance(col1, col2); 
#       where distance(col1, col2) < 0.5;
def gen_project_func(tree):
    if isinstance(tree,TableNode):
        if tree.select_list != None:
            tree.func_list = []
            tree.func_alias = {}
            func_list = tree.select_list.tmp_exp_list
            for exp in func_list:
                new_exp = copy.deepcopy(exp)
                tree.func_alias[new_exp] = tree.select_list.dict_exp_and_alias[exp]
                tree.func_list.append(new_exp)
        
        # detect distance() or outlier_score() in select and where
        # initial a project_func_list to record above two funtions
        tree.project_func_list = []

        # detect above two funtions
        # e.g. DISTANCE(VECTOR, PATH)
        # if tree.where_condition != None:
        #     exp_list = []
        #     __get_func_exp__(tree.where_condition.where_condition_exp, exp_list)
        #     for exp in exp_list: 
        #         if isinstance(exp, YFuncExp):
        #             if exp.func_name in ["DISTANCE", "OUTLIER_SCORE"]:
        #                 insert = True
        #                 for project_func in tree.project_func_list:
        #                     if exp.compare(project_func):
        #                         insert = False
        #                 if insert == True:
        #                     tmp_exp = copy.deepcopy(exp)
        #                     tree.project_func_list.append(tmp_exp)

        if tree.select_list != None:
            for exp in tree.select_list.tmp_exp_list:
                if isinstance(exp, YFuncExp):
                    if exp.func_name in ["DISTANCE"]:
                        insert = True
                        for project_func in tree.project_func_list:
                            if exp.compare(project_func):
                                insert = False
                        if insert == True:
                            tmp_exp = copy.deepcopy(exp)
                            if isDistanceTwoCol(tmp_exp):
                                tmp_exp.project_res_index = tree.select_list.tmp_exp_list.index(exp)
                                tmp_exp.func_list_index = tree.select_list.tmp_exp_list.index(exp)
                            tree.project_func_list.append(tmp_exp)
                    else:
                        # detect above two funtions in parameter_list
                        # e.g. VIDEO_SIMILARITY(DISTANCE(VECTOR1, VECTOR2))
                        for exp_param in exp.parameter_list:
                            if isinstance(exp_param, YFuncExp):
                                if exp_param.func_name in ["DISTANCE"]: 
                                    insert = True
                                    exp_param.inner = 1
                                    for project_func in tree.project_func_list:
                                        if exp_param.compare(project_func):
                                            insert = False
                                            project_func.inner = 1
                                    if insert == True:
                                        tmp_exp = copy.deepcopy(exp_param)
                                        if isDistanceTwoCol(tmp_exp):
                                            tmp_exp.project_res_index = tree.select_list.tmp_exp_list.index(exp)
                                            tmp_exp.func_list_index = tree.select_list.tmp_exp_list.index(exp_param)
                                        tree.project_func_list.append(tmp_exp)

        return

    elif isinstance(tree,OrderByNode):
        gen_project_func(tree.child)

    elif isinstance(tree,GroupByNode):
        gen_project_func(tree.child)

    elif isinstance(tree,TwoJoinNode):
        if tree.select_list != None:
            tree.func_list = []
            tree.func_alias = {}
            func_list = tree.select_list.tmp_exp_list
            for exp in func_list:
                new_exp = copy.deepcopy(exp)
                tree.func_alias[new_exp] = tree.select_list.dict_exp_and_alias[exp]
                tree.func_list.append(new_exp)
        
        # detect distance() or outlier_score() in select and where
        # initial a project_func_list to record above two funtions
        tree.project_func_list = []

        # detect above two funtions
        # e.g. DISTANCE(VECTOR, PATH)
        # if tree.where_condition != None:
        #     exp_list = []
        #     __get_func_exp__(tree.where_condition.where_condition_exp, exp_list)
        #     for exp in exp_list: 
        #         if isinstance(exp, YFuncExp):
        #             if exp.func_name in ["DISTANCE", "OUTLIER_SCORE"]:
        #                 insert = True
        #                 for project_func in tree.project_func_list:
        #                     if exp.compare(project_func):
        #                         insert = False
        #                 if insert == True:
        #                     tmp_exp = copy.deepcopy(exp)
        #                     tree.project_func_list.append(tmp_exp)

        # if tree.join_condition != None:
        #     if tree.join_explicit is False and tree.join_condition.where_condition_exp != None:
        #         exp = tree.join_condition.where_condition_exp
        #         if isinstance(exp, YFuncExp):
        #             # detect above two funtions in parameter_list
        #             # e.g. DISTANCE(VECTOR1, VECTOR2) < 0.5
        #             for exp_param in exp.parameter_list:
        #                 if isinstance(exp_param, YFuncExp):
        #                     if exp_param.func_name in ["DISTANCE"]: 
        #                         tmp_exp = copy.deepcopy(exp_param)
        #                         tree.project_func_list.append(tmp_exp)                
        
        if tree.select_list != None:
            for exp in tree.select_list.tmp_exp_list:
                if isinstance(exp, YFuncExp):
                    if exp.func_name in ["DISTANCE"]:
                        tmp_exp = copy.deepcopy(exp)
                        if isDistanceTwoCol(tmp_exp):
                            tmp_exp.project_res_index = tree.select_list.tmp_exp_list.index(exp)
                            tmp_exp.func_list_index = tree.select_list.tmp_exp_list.index(exp)
                        tree.project_func_list.append(tmp_exp)
                    elif exp.func_name in ["SUM", "VIDEO_SIMILARITY"]:
                        # detect above two funtions in parameter_list
                        # e.g. VIDEO_SIMILARITY(DISTANCE(v1, v2))
                        # e.g. OUTLIER_SCORE(KNN_AVG_DISTANCE(v1, v2))
                        for exp_param in exp.parameter_list:
                            if isinstance(exp_param, YFuncExp) and exp_param.func_name in ["DISTANCE"]: 
                                tmp_exp = copy.deepcopy(exp_param)
                                if isDistanceTwoCol(tmp_exp) or (isinstance(tmp_exp, YFuncExp) and tmp_exp.func_name == "KNN_AVG_DISTANCE"):
                                    tmp_exp.project_res_index = tree.select_list.tmp_exp_list.index(exp)
                                    tmp_exp.func_list_index = tree.select_list.tmp_exp_list.index(exp)
                                tree.project_func_list.append(tmp_exp)

        gen_project_func(tree.left_child)
        gen_project_func(tree.right_child)

    elif isinstance(tree,SelectProjectNode):
        gen_project_func(tree.child)
## input exp should be YRawColExp
## return new_exp
def __gen_column_index__(exp,table_list,table_alias_dict):

    if exp is None:
        return None

    new_exp = None

    if isinstance(exp,YRawColExp):
        if exp.column_name == "*":
##
## * should be handled separately by select_list
##
            new_exp = exp
            return new_exp

        if exp.table_name != "":
            if exp.table_name not in table_alias_dict.keys():
                if exp.table_name not in table_list:
                    print >>sys.stderr,"Internal Error:__gen_column_index__"
                    exit(29)
                tmp_table =  lookup_a_table(exp.table_name)

                if tmp_table is None:
                    return None

                index = tmp_table.get_column_index_by_name(exp.column_name)

### be careful that the column_name returned by YRawColExp is str, not int. We need to change it to int

                new_exp = YRawColExp(exp.table_name,index)
                new_exp.column_name = int(new_exp.column_name)
                new_exp.column_type = exp.column_type
            else:
                tmp_table = lookup_a_table(table_alias_dict[exp.table_name])

                if tmp_table is None:
                    return None

                index = tmp_table.get_column_index_by_name(exp.column_name)
                new_exp = YRawColExp(exp.table_name,index)
                new_exp.column_name = int(new_exp.column_name)
                new_exp.column_type = exp.column_type
        else:
            tmp_column = lookup_a_column(exp.column_name)
            tmp_table = None
            for tmp in tmp_column:
                if tmp.table_schema.table_name in table_list:
                    tmp_table = lookup_a_table(tmp.table_schema.table_name)
                    break
                if tmp.table_schema.table_name in table_alias_dict.values():
                    tmp_table = lookup_a_table(tmp.table_schema.table_name)
                    break
            if tmp_table is None:
                return None

            index = tmp_table.get_column_index_by_name(exp.column_name)
            new_exp = YRawColExp(tmp.table_schema.table_name,index)
            new_exp.column_name = int(new_exp.column_name)
            new_exp.column_type = exp.column_type

        return new_exp

def __gen_func_index__(exp,table_list,table_alias_dict):

    if isinstance(exp,YFuncExp) is not True:
        print >>sys.stderr,"Internal Error:__gen_func_index__"
        exit(29)

    if exp is None:
        return None


    if isinstance(exp,YFuncExp):
        para_list = exp.parameter_list
        new_para_list = []
        for para in para_list:
            if isinstance(para,YRawColExp):
                if para.column_name == "*":
                    print >>sys.stderr,"Internal Error:__gen_func_index__"
                    exit(29)
                if para.table_name in table_list:
                    new_para = __gen_column_index__(para,table_list,table_alias_dict)
                    if new_para is None:
                        print >>sys.stderr,"Internal Error:__gen_func_index__"
                        exit(29)

                    new_para_list.append(new_para)
                else:
                    new_para_list.append(para)

            elif isinstance(para,YFuncExp):
                tmp_exp = __gen_func_index__(para,table_list,table_alias_dict)
                if tmp_exp is None:
                    print >>sys.stderr,"Internal Error:__gen_func_index__"
                    exit(29)

                new_para_list.append(tmp_exp)

            elif isinstance(para,YConsExp):
                if para.ref_col is not None:
                    new_col = __gen_column_index__(para.ref_col, [para.ref_col.table_name], {})
                    para.ref_col.table_name = new_col.table_name
                    para.ref_col.column_name = new_col.column_name
                    para.ref_col.column_type = new_col.column_type
                    para.ref_col.func_obj = new_col.func_obj
                new_para_list.append(para)

        new_exp = YFuncExp(exp.func_name,list(new_para_list))

    return new_exp


def __gen_select_index__(select_list,table_list,table_alias_dict):

    if select_list is None:
        return
    new_select_dict = {}
    new_exp_list = []
    exp_dict = select_list.dict_exp_and_alias.copy()
    exp_list = select_list.tmp_exp_list

    for exp in exp_list:
        if isinstance(exp,YRawColExp):

            new_exp = __gen_column_index__(exp,table_list,table_alias_dict)
            if new_exp is None:
                print >>sys.stderr,"Internal Error:__gen_select_index__"
                exit(29)
            new_select_dict[new_exp] = select_list.dict_exp_and_alias[exp]
            new_exp_list.append(new_exp)

        elif isinstance(exp,YFuncExp):
            new_exp = __gen_func_index__(exp,table_list,table_alias_dict)
            new_exp_list.append(new_exp)
            new_select_dict[new_exp] = None
        else:
            new_exp_list.append(exp)
            new_select_dict[exp] = None

    select_list.dict_exp_and_alias = new_select_dict
    select_list.tmp_exp_list = new_exp_list



def __gen_where_index__(where,table_list,table_alias_dict):
    if where is None:
        return

    if isinstance(where.where_condition_exp,YFuncExp):
        where.where_condition_exp =__gen_func_index__(where.where_condition_exp,table_list,table_alias_dict)

def __get_gb_list__(exp,col_list):
    if isinstance(exp,YFuncExp) is False:
        print >>sys.stderr,"Internal Error:__get_gb_list__"
        exit(29)

    if exp.func_name in ["AND","OR"]:
        for x in exp.parameter_list:
            if isinstance(x,YFuncExp):
                __get_gb_list__(x,col_list)

    elif exp.func_name in agg_func_list:
        col_list.append(exp)
    else:
        for x in exp.parameter_list:
            if isinstance(x,YFuncExp):
                __get_gb_list__(x,col_list)

class function_list:
    tmp_exp_list = None
    dict_exp_and_alias = None
    def __init__(self):
        pass

def gen_column_index(tree):

    if isinstance(tree,TableNode):
        __gen_select_index__(tree.select_list,tree.table_list,tree.table_alias_dict)
        __gen_where_index__(tree.where_condition,tree.table_list,tree.table_alias_dict)

        # process DISTANCE() OUTLIER_SCORE() VIDEO_SIMILARITY() function
        if tree.func_list is not None:
            func_list = function_list()
            func_list.tmp_exp_list = tree.func_list
            func_list.dict_exp_and_alias = tree.func_alias
            __gen_select_index__(func_list,tree.table_list,tree.table_alias_dict)
            tree.func_list = func_list.tmp_exp_list
            tree.func_alias = func_list.dict_exp_and_alias
        if tree.project_func_list is not None:
            for exp in tree.project_func_list:
                if isinstance(exp, YFuncExp):
                    for exp_param in exp.parameter_list:
                        if isinstance(exp_param, YRawColExp):
                            new_exp = __gen_column_index__(exp_param, tree.table_list, tree.table_alias_dict)
                            exp_param.column_name = new_exp.column_name

        return
    if isinstance(tree,OrderByNode):

        select_dict = tree.child.select_list.dict_exp_and_alias
        exp_list = tree.child.select_list.tmp_exp_list

        if (isinstance(tree.child, TableNode) or isinstance(tree.child, TwoJoinNode)):
            select_dict = tree.child.func_alias
            exp_list = tree.child.func_list

        new_orderby_exp_list = []

        if tree.order_by_clause is not None:
            for exp in tree.order_by_clause.orderby_exp_list:
                if isinstance(exp,YRawColExp):
                    for tmp in exp_list:
                        if isinstance(tmp,YRawColExp):
                            if exp.table_name == tmp.table_name and exp.column_name == tmp.column_name:
                                exp.column_name = exp_list.index(tmp)
                                new_orderby_exp_list.append(exp);
                                break
                        else:
                            if exp.column_name == select_dict[tmp]:
                                exp.column_name = exp_list.index(tmp)
                                new_orderby_exp_list.append(exp);
                                break

                elif isinstance(exp,YFuncExp):
                    for tmp in exp_list:
                        if isinstance(tmp,YFuncExp):
                            if tmp.compare(exp):
                                index = exp_list.index(tmp)
                                newCol = YRawColExp("",str(index));
                                new_orderby_exp_list.append(newCol)

            tree.order_by_clause.orderby_exp_list = new_orderby_exp_list

        gen_column_index(tree.child)

    elif isinstance(tree,GroupByNode):
        if tree.select_list is None or tree.child.select_list is None:
            print >>sys.stderr,"Internal Error:gen_column_index"
            exit(29)

        select_dict = tree.child.select_list.dict_exp_and_alias
        exp_list = tree.child.select_list.tmp_exp_list

### generate index for the groupby clause.

        if tree.group_by_clause is not None:
            for exp in tree.group_by_clause.groupby_exp_list:
                if isinstance(exp,YRawColExp):
                    for tmp in exp_list:
                        if isinstance(tmp,YRawColExp):
                            if exp.table_name == tmp.table_name and exp.column_name == tmp.column_name:
                                exp.column_name = exp_list.index(tmp)
                                break
                        else:
                            if exp.column_name == select_dict[tmp]:
                                exp.column_name = exp_list.index(tmp)
                                break

        if tree.where_condition is not None:
###
### generate index for all the rest colExp in the where exp
###
            col_list = []
            __get_func_para__(tree.where_condition.where_condition_exp,col_list)
            for exp in col_list:
                for tmp in exp_list:
                    if isinstance(tmp,YRawColExp):
                        if exp.table_name == tmp.table_name and exp.column_name == tmp.column_name:
                            exp.column_name = exp_list.index(tmp)
                            break
                    else:
                        if exp.column_name == select_dict[tmp]:
                            exp.column_name = exp_list.index(tmp)
                            break

        for exp in tree.select_list.tmp_exp_list:
## generate index for the select list first

            if isinstance(exp,YRawColExp):
                for tmp in exp_list:
                    if isinstance(tmp,YRawColExp):
                        if exp.table_name == tmp.table_name and exp.column_name == tmp.column_name:
                            exp.column_name = exp_list.index(tmp)
                            break
                    else:
                        if exp.column_name == select_dict[tmp]:
                            exp.column_name = exp_list.index(tmp)
                            break

            elif isinstance(exp,YFuncExp):
                col_list = []
                __get_func_para__(exp,col_list)
                for tmp in col_list:
                    for x in exp_list:
                        if isinstance(x,YRawColExp):
                            if x.table_name == tmp.table_name and x.column_name == tmp.column_name:
                                tmp.column_name = exp_list.index(x)
                                break

                        else:
                            if tmp.column_name == select_dict[x]:
                                tmp.column_name = exp_list.index(x)
                                break

        gen_column_index(tree.child)

    elif isinstance(tree,TwoJoinNode):
        
        # process DISTANCE() OUTLIER_SCORE() VIDEO_SIMILARITY() function
        if tree.func_list is not None:
            func_list = function_list()
            func_list.tmp_exp_list = tree.func_list
            func_list.dict_exp_and_alias = tree.func_alias
            __gen_select_index__(func_list,tree.table_list,tree.table_alias_dict)
            tree.func_list = func_list.tmp_exp_list
            tree.func_alias = func_list.dict_exp_and_alias
        if tree.project_func_list is not None:
            for exp in tree.project_func_list:
                if isinstance(exp, YFuncExp):
                    for exp_param in exp.parameter_list:
                        if isinstance(exp_param, YRawColExp):
                            new_exp = __gen_column_index__(exp_param, tree.table_list, tree.table_alias_dict)
                            exp_param.column_name = new_exp.column_name

        left_select = None
        right_select = None

        tree.table_list =[]

##table_alias_dict is not changed. It is used to determine whether this is a self join
## change the table name  to LEFT and RIGHT

        join_exp = None
        if tree.join_explicit is True:
            join_exp = tree.join_condition.on_condition_exp

        elif tree.join_condition is not None and not isinstance(tree.join_condition, str):
            join_exp = tree.join_condition.where_condition_exp

        else:
            join_exp = None

        if tree.left_child.select_list is not None:
            left_select = tree.left_child.select_list.dict_exp_and_alias
            left_exp = tree.left_child.select_list.tmp_exp_list

####first generate index for the join key
#### if the child is tablenode, generating the index based on the table schema. otherwise based on the child's select_list

            if join_exp is not None:
                if isinstance(tree.left_child,TableNode):
                    if tree.join_explicit is True:
                            tree.join_condition.on_condition_exp = __gen_func_index__(tree.join_condition.on_condition_exp,tree.left_child.table_list,tree.table_alias_dict)
                            col_list = []
                            __get_func_para__(tree.join_condition.on_condition_exp,col_list)
                            for x in col_list:
                                if x.table_name in tree.left_child.table_list:
                                    x.past_table_name = x.table_name
                                    x.table_name ="LEFT"
                                    tree.table_list.append("LEFT")
                    elif tree.join_condition is not None:
                        tree.join_condition.where_condition_exp = __gen_func_index__(tree.join_condition.where_condition_exp,tree.left_child.table_list,tree.table_alias_dict)
                        col_list = []
                        __get_func_para__(tree.join_condition.where_condition_exp,col_list)
                        for x in col_list:
                            if x.table_name in tree.left_child.table_list:
                                x.past_table_name = x.table_name
                                x.table_name ="LEFT"
                                tree.table_list.append("LEFT")
                else:
                    col_list = []
                    __get_func_para__(join_exp,col_list)
                    for tmp in col_list:
                        for x in left_exp:
                            if isinstance(x,YRawColExp):
                                if tmp.column_name == x.column_name and tmp.table_name == x.table_name:
                                    tmp.past_table_name = tmp.table_name
                                    tmp.table_name = "LEFT"
                                    tmp.column_name = left_exp.index(x)
                                    if "LEFT" not in tree.table_list:
                                        tree.table_list.append("LEFT")
                                    break
                                else:
                                    if tmp.column_name == left_select[x]:
                                        tmp.past_table_name = tmp.table_name
                                        tmp.table_name = "LEFT"
                                        tmp.column_name = left_exp.index(x)
                                        if "LEFT" not in tree.table_list:
                                            tree.table_list.append("LEFT")
                                        break

###generate index for the select list

            for exp in tree.select_list.tmp_exp_list:
                if isinstance(exp,YConsExp):
                    continue

                elif isinstance(exp,YFuncExp):
                    col_list = []
                    __get_func_para__(exp,col_list)
                    for x in col_list:
                        for tmp in left_exp:
                            if isinstance(tmp,YRawColExp):
                                if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                                    x.past_table_name = x.table_name
                                    x.table_name = "LEFT"
                                    x.column_name = left_exp.index(tmp)
                                    if "LEFT" not in tree.table_list:
                                        tree.table_list.append("LEFT")
                                    break
                            else:
                                if x.column_name == left_select[tmp]:
                                    x.past_table_name = x.table_name
                                    x.table_name = "LEFT"
                                    if "LEFT" not in tree.table_list:
                                        tree.table_list.append("LEFT")
                                    x.column_name = left_exp.index(tmp)
                                    break
                    continue

                for tmp in left_exp:
                    if isinstance(tmp,YRawColExp):
                        if exp.column_name == tmp.column_name and exp.table_name == tmp.table_name:
                            exp.past_table_name = exp.table_name
                            exp.table_name = "LEFT"
                            exp.column_name = left_exp.index(tmp)
                            if "LEFT" not in tree.table_list:
                                tree.table_list.append("LEFT")
                            break
                    else:
                        if exp.column_name == left_select[tmp]:
                            exp.past_table_name = exp.table_name
                            exp.table_name = "LEFT"
                            if "LEFT" not in tree.table_list:
                                tree.table_list.append("LEFT")
                            exp.column_name = left_exp.index(tmp)
                            break

### generate index for where expression

            if tree.where_condition is not None:
                where_exp = tree.where_condition.where_condition_exp
                col_list = []
                __get_func_para__(where_exp,col_list)
                for tmp in col_list:
                    for x in left_exp:
                        if isinstance(x,YRawColExp):
                            if tmp.column_name == x.column_name and tmp.table_name == x.table_name:
                                tmp.past_table_name = tmp.table_name
                                tmp.table_name = "LEFT"
                                tmp.column_name = left_exp.index(x)
                                if "LEFT" not in tree.table_list:
                                    tree.table_list.append("LEFT")
                                break
                        else:
                            if tmp.column_name == left_select[x]:
                                tmp.past_table_name = tmp.table_name
                                tmp.table_name = "LEFT"
                                tmp.column_name = left_exp.index(x)
                                if "LEFT" not in tree.table_list:
                                    tree.table_list.append("LEFT")
                                break

        join_exp = None
        if tree.join_explicit is True:
            join_exp = tree.join_condition.on_condition_exp

        elif tree.join_condition is not None and not isinstance(tree.join_condition, str):
            join_exp = tree.join_condition.where_condition_exp

        else:
            join_exp = None

        if tree.right_child.select_list is not None:
            right_select = tree.right_child.select_list.dict_exp_and_alias
            right_exp = tree.right_child.select_list.tmp_exp_list


            if join_exp is not None:
                col_list = []
                __get_func_para__(join_exp,col_list)

                if isinstance(tree.right_child,TableNode) is True:
                    if tree.join_explicit is True:
                            tree.join_condition.on_condition_exp = __gen_func_index__(tree.join_condition.on_condition_exp,tree.right_child.table_list,tree.table_alias_dict)
                            col_list = []
                            __get_func_para__(tree.join_condition.on_condition_exp,col_list)
                            for x in col_list:
                                if x.table_name in tree.right_child.table_list:
                                    x.table_name ="RIGHT"
                                    tree.table_list.append("RIGHT")
                    elif tree.join_condition is not None:
                        tree.join_condition.where_condition_exp = __gen_func_index__(tree.join_condition.where_condition_exp,tree.right_child.table_list,tree.table_alias_dict)
                        col_list = []
                        __get_func_para__(tree.join_condition.where_condition_exp,col_list)
                        for x in col_list:
                            if x.table_name in tree.right_child.table_list:
                                x.table_name ="RIGHT"
                                tree.table_list.append("RIGHT")
                else:
                        for tmp in col_list:
                            for x in right_exp:
                                if isinstance(x,YRawColExp):
                                    if tmp.column_name == x.column_name and tmp.table_name == x.table_name:
                                        tmp.table_name = "RIGHT"
                                        tmp.column_name = right_exp.index(x)
                                        if "RIGHT" not in tree.table_list:
                                            tree.table_list.append("RIGHT")
                                        break
                                else:
                                    if tmp.column_name == right_select[x]:
                                        tmp.table_name = "RIGHT"
                                        tmp.column_name = right_exp.index(x)
                                        if "RIGHT" not in tree.table_list:
                                            tree.table_list.append("RIGHT")
                                        break


            for exp in tree.select_list.tmp_exp_list:
                if isinstance(exp,YConsExp):
                    continue

                elif isinstance(exp,YFuncExp):
                    col_list = []
                    __get_func_para__(exp,col_list)
                    for x in col_list:
                        for tmp in right_exp:
                            if isinstance(tmp,YRawColExp):
                                if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                                    x.table_name = "RIGHT"
                                    x.column_name = right_exp.index(tmp)
                                    if "RIGHT" not in tree.table_list:
                                        tree.table_list.append("RIGHT")
                                    break
                            else:
                                if x.column_name == right_select[tmp]:
                                    x.table_name = "RIGHT"
                                    if "RIGHT" not in tree.table_list:
                                        tree.table_list.append("RIGHT")
                                    x.column_name = right_exp.index(tmp)
                                    break
                    continue

                for tmp in right_exp:
                    if isinstance(tmp,YRawColExp):
                        if exp.column_name == tmp.column_name and exp.table_name == tmp.table_name:
                            exp.table_name = "RIGHT"
                            exp.column_name = right_exp.index(tmp)
                            if "RIGHT" not in tree.table_list:
                                tree.table_list.append("RIGHT")
                            break
                    else:
                        if exp.column_name == right_select[tmp]:
                            exp.table_name = "RIGHT"
                            exp.column_name = right_exp.index(tmp)
                            if "RIGHT" not in tree.table_list:
                                tree.table_list.append("RIGHT")

            if tree.where_condition is not None:
                where_exp = tree.where_condition.where_condition_exp
                col_list = []
                __get_func_para__(where_exp,col_list)

                for tmp in col_list:
                    for x in right_exp:
                        if isinstance(x,YRawColExp):
                            if tmp.column_name == x.column_name and tmp.table_name == x.table_name:
                                tmp.table_name = "RIGHT"
                                tmp.column_name = right_exp.index(x)
                                if "RIGHT" not in tree.table_list:
                                    tree.table_list.append("RIGHT")
                                break
                        else:
                            if tmp.column_name == right_select[x]:
                                tmp.table_name = "RIGHT"
                                tmp.column_name = right_exp.index(x)
                                if "RIGHT" not in tree.table_list:
                                    tree.table_list.append("RIGHT")
                                break

        gen_column_index(tree.left_child)
        gen_column_index(tree.right_child)

    elif isinstance(tree,MultipleJoinNode):
        pass

    elif isinstance(tree,SelectProjectNode):
        __gen_select_index__(tree.select_list,tree.table_list,tree.table_alias_dict)
        __gen_where_index__(tree.where_condition,tree.table_list,tree.table_alias_dict)
        gen_column_index(tree.child)



def __gen_project_list__(select_list,table_list,table_alias_dict,project_list):

    exp_dict = select_list.dict_exp_and_alias

    for exp in select_list.tmp_exp_list:
        col_type = None

        if isinstance(exp,YRawColExp):
            if exp.column_name == "*":
                for tmp in table_list:
                    tmp_table = lookup_a_table(tmp)
                    if tmp_table is None:
                        continue

                    for x in tmp_table.column_list:
                        tmp_col = copy.deepcopy(x)
                        project_list.append(tmp_col)

                for tmp in table_alias_dict.values():
                    tmp_table = lookup_a_table(tmp)
                    if tmp_table is None:
                        continue

                    for x in tmp_table.column_list:
                        tmp_col = copy.deepcopy(x)
                        project_list.append(tmp_col)

                continue


            tmp_column = lookup_a_column(exp.column_name)
            for tmp in tmp_column:
                if tmp.table_schema.table_name in table_list :

                    col_type = tmp.table_schema.get_column_type_by_name(exp.column_name)
                    break

                if tmp.table_schema.table_name in table_alias_dict.values():

                    col_type = tmp.table_schema.get_column_type_by_name(exp.column_name)
                    break


            if col_type is not None:
                if exp_dict[exp] is not None:
                    a_col = ColumnSchema(exp_dict[exp],col_type)
                else:
                    a_col = ColumnSchema(exp.column_name,col_type)
                project_list.append(a_col)

        elif isinstance(exp,YFuncExp):
            if exp_dict[exp] is not None:
                col_type = exp.get_value_type()
                a_col = ColumnSchema(exp_dict[exp],col_type)
                project_list.append(a_col)
        else:
            print >>sys.stderr,"Internal Error:__gen_project_list__"
            exit(29)


def gen_project_list(tree):

    if isinstance(tree,TableNode):
        return
    elif isinstance(tree,OrderByNode):
        gen_project_list(tree.child)

    elif isinstance(tree,GroupByNode):
        gen_project_list(tree.child)
        # Add grammar: if SelectProjectNode is GroupNode's child, we need to add table_list because it is not processed before
        # if isinstance(tree.child, SelectProjectNode):
        #     for x in tree.child.table_list:
        #         if x not in tree.table_list and x not in tree.child.table_alias_dict:
        #             tree.table_list.append(x)

    elif isinstance(tree,TwoJoinNode):
        gen_project_list(tree.left_child)

        gen_project_list(tree.right_child)

    elif isinstance(tree,SelectProjectNode):
        gen_project_list(tree.child)

        # for x in tree.child.table_list:
        #     if x not in tree.table_list and x not in tree.child.table_alias_dict:
        #         tree.table_list.append(x)

        for tmp in tree.child.table_list:
            if tmp not in tree.in_table_list:
                tree.in_table_list.append(tmp)
        tree.in_table_alias_dict = tree.child.table_alias_dict


        project_list = []
        __gen_project_list__(tree.child.select_list,tree.in_table_list,tree.in_table_alias_dict,project_list)
        dup_bool = False

        tmp_name = tree.table_alias

        if tmp_name not in global_table_dict.keys():
            tmp_schema = TableSchema(tmp_name,project_list)
            global_table_dict[tmp_name] = tmp_schema

        else:
            while tmp_name in global_table_dict.keys():
                tmp_name = tmp_name + "_1"
            tmp_schema = TableSchema(tmp_name,project_list)
            global_table_dict[tmp_name] = tmp_schema

    else:
        return


def __select_list_filter__(select_list,table_list,table_alias_dict,new_select_dict,new_exp_list):

    math_func_list = ["PLUS","MINUS","DIVIDE","MULTIPLY"]

    if select_list is None:
        return


    for exp in select_list.tmp_exp_list:
        if isinstance(exp,YRawColExp):
            for tmp in table_list:
                if tmp != exp.table_name:
                    continue

                if column_in_table(exp.column_name,tmp):
                    tmp_bool = False
                    for x in new_exp_list:
                        if x.column_name == exp.column_name and x.table_name == tmp:
                            tmp_bool = True
                            break

                    if tmp_bool is False:
                        new_exp = copy.deepcopy(exp)
                        new_exp_list.append(new_exp)
                        new_select_dict[new_exp] = select_list.dict_exp_and_alias[exp]
                    break

            for tmp in table_alias_dict.keys():
                if tmp != exp.table_name:
                    continue

                if column_in_table(exp.column_name,table_alias_dict[tmp]):
                    tmp_bool = False
                    for x in new_exp_list:
                        if x.column_name == exp.column_name and x.table_name == tmp:
                            tmp_bool = True
                            break

                    if tmp_bool is False:
                        new_exp = copy.deepcopy(exp)
                        new_exp_list.append(new_exp)
                        new_select_dict[new_exp] = select_list.dict_exp_and_alias[exp]
                    break

        elif isinstance(exp,YFuncExp):
            col_list = []
            __get_func_para__(exp,col_list)
            for tmp in col_list:
                if tmp.table_name not in table_list:
                    continue

                tmp_bool = False
                for x in new_exp_list:
                    if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                        tmp_bool = True
                        break

                if tmp_bool is False:
                    new_exp = copy.deepcopy(tmp)
                    new_exp_list.append(new_exp)
                    new_select_dict[new_exp] = None


    return


##return all the YRawColExp in the YFuncExp
#the col_list contains the reference, so the changing of col_list will also result a change in exp
def __get_func_para__(exp,col_list):

    if not isinstance(exp,YFuncExp):
        return

    for para in exp.parameter_list:
        if isinstance(para,YRawColExp):
            col_list.append(para)

        elif isinstance(para,YFuncExp):
            __get_func_para__(para,col_list)

##return all the YFuncExp in the YFuncExp
#the func_list contains the reference, so the changing of col_list will also result a change in exp
def __get_func_exp__(exp,func_list):

    if not isinstance(exp,YFuncExp):
        return

    func_list.append(exp)

    for para in exp.parameter_list:
        if isinstance(para,YFuncExp):
            __get_func_exp__(para,func_list)

## for join select_list pruning. add where and join_cond to the child's select_lsit
def __add_func_to_select__(exp,table_list,table_alias_dict,new_dict,new_list):

    bool_func_list = ["AND","OR"]

    if exp is None or not isinstance(exp,YFuncExp):
        return

    if exp.func_name in bool_func_list:
        for para in exp.parameter_list:
            if isinstance(para,YFuncExp):
                __add_func_to_select__(para,table_list,table_alias_dict,new_dict,new_list)

    else:
        col_list = []
        __get_func_para__(exp,col_list)

        for x in col_list:
            if x.table_name not in table_list and x.table_name not in table_alias_dict.values():
                continue

            tmp_bool = False
            for tmp in new_list:
                if tmp.table_name == x.table_name and tmp.column_name == x.column_name:
                    tmp_bool = True
                    break

            if tmp_bool == False:
                tmp_col = copy.deepcopy(x)
                new_list.append(tmp_col)
                new_dict[tmp_col] = None


def column_filtering(tree):
    math_func_list = ["PLUS","MINUS","DIVIDE","MULTIPLY"]

    if isinstance(tree,TableNode):
        new_select_dict = {}
        new_exp_list = []

        # if no parent or parent is OrderByNode
        # we need to do column filtering and process function in TableNode
        if tree.parent == None or isinstance(tree.parent,OrderByNode): 
            # column filtering     
            if tree.select_list is not None:
                for exp in tree.select_list.tmp_exp_list:
                    if isinstance(exp,YRawColExp):
                        tmp_bool = False
                        for tmp in new_exp_list:
                            if not isinstance(tmp,YRawColExp):
                                continue
                            if tmp.column_name == exp.column_name and tmp.table_name == exp.table_name:
                                tmp_bool = True
                                break

                        if tmp_bool is False:
                            new_exp = copy.deepcopy(exp)
                            new_exp_list.append(new_exp)
                            new_select_dict[new_exp] = tree.select_list.dict_exp_and_alias[exp]

                    elif isinstance(exp,YFuncExp):

                        col_list = []
                        __get_func_para__(exp,col_list)
                        for tmp in col_list:
                            tmp_bool = False
                            for x in new_exp_list:
                                if not isinstance(x,YRawColExp):
                                    continue
                                if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                                    tmp_bool = True
                                    break

                            if tmp_bool is False:
                                new_exp = copy.deepcopy(tmp)
                                new_exp_list.append(new_exp)
                                new_select_dict[new_exp] = None
            
            tree.select_list.dict_exp_and_alias = new_select_dict
            tree.select_list.tmp_exp_list = new_exp_list
        return

    elif isinstance(tree,OrderByNode):
#### push all the exp in the orderby_exp_list to the child's select_list

        new_select_dict = {}
        new_exp_list = []

        for exp in tree.order_by_clause.orderby_exp_list:
            if isinstance(exp,YRawColExp):
                for x in tree.child.select_list.tmp_exp_list:
                    if exp.column_name == tree.child.select_list.dict_exp_and_alias[x]:
                        new_exp = copy.deepcopy(x)
                        new_exp_list.append(new_exp)
                        new_select_dict[new_exp] = None
            else:
                new_exp = copy.deepcopy(exp)
                new_exp_list.append(new_exp)
                new_select_dict[new_exp] = None

####remove alias in the order_by_list
        tree.order_by_clause.orderby_exp_list = copy.deepcopy(new_exp_list)

        new_select_dict = {}
        new_exp_list = []

        for exp in tree.child.select_list.tmp_exp_list:
            new_exp = copy.deepcopy(exp)
            new_exp_list.append(new_exp)
            new_select_dict[new_exp] = tree.child.select_list.dict_exp_and_alias[exp]

        tree.child.select_list.tmp_exp_list = new_exp_list
        tree.child.select_list.dict_exp_and_alias = new_select_dict

        column_filtering(tree.child)

    elif isinstance(tree,GroupByNode):

        new_select_dict = {}
        new_exp_list = []

        if tree.group_by_clause is not None:
### push all the columns in the groupby exp to its child's select_list

            for exp in tree.group_by_clause.groupby_exp_list:
                if isinstance(exp,YFuncExp):
                    col_list = []
                    __get_func_para__(exp,col_list)
                    tmp_bool = False
                    for x in col_list:
                        for tmp in new_exp_list:
                            if x.table_name == tmp.table_name and x.column_name == tmp.column_name:
                                tmp_bool = True
                                break

                        if tmp_bool is False:
                            new_exp = copy.deepcopy(x)
                            new_exp_list.append(new_exp)
                            new_select_dict[new_exp] = None

                elif isinstance(exp,YRawColExp):
                    tmp_bool = False
                    for tmp in new_exp_list:
                        if tmp.table_name == exp.table_name and tmp.column_name == exp.column_name:
                            tmp_bool = True
                            break

                    if tmp_bool is False:
                        new_exp = copy.deepcopy(exp)
                        new_exp_list.append(new_exp)
                        new_select_dict[new_exp] = None

        else:
            print >>sys.stderr,"Internal Error:column_filtering"
            exit(29)


        if tree.where_condition is not None:
            col_list = []
            __get_gb_list__(tree.where_condition.where_condition_exp,col_list)
            for x in col_list:
                tmp_bool = False
                for tmp in tree.select_list.tmp_exp_list:
                    if x.compare(tmp) is True:
                        tmp_bool = True
                        break

                if tmp_bool is False:
                    new_exp = copy.deepcopy(x)
                    tree.select_list.tmp_exp_list.append(new_exp)
                    tree.select_list.dict_exp_and_alias[new_exp] = None

        if tree.select_list is not None:

            for exp in tree.select_list.tmp_exp_list:
                if isinstance(exp,YRawColExp):
                    tmp_bool = False
                    for tmp in new_exp_list:
                        if not isinstance(tmp,YRawColExp):
                            continue
                        if tmp.column_name == exp.column_name and tmp.table_name == exp.table_name:
                            tmp_bool = True
                            break

                    if tmp_bool is False:
                        new_exp = copy.deepcopy(exp)
                        new_exp_list.append(new_exp)
                        new_select_dict[new_exp] = tree.select_list.dict_exp_and_alias[exp]

                elif isinstance(exp,YFuncExp):

                    col_list = []
                    __get_func_para__(exp,col_list)
                    for tmp in col_list:
                        tmp_bool = False
                        for x in new_exp_list:
                            if not isinstance(x,YRawColExp):
                                continue
                            if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                                tmp_bool = True
                                break

                        if tmp_bool is False:
                            new_exp = copy.deepcopy(tmp)
                            new_exp_list.append(new_exp)
                            new_select_dict[new_exp] = None

        tree.child.select_list.dict_exp_and_alias = new_select_dict
        tree.child.select_list.tmp_exp_list = new_exp_list

        column_filtering(tree.child)

    elif isinstance(tree,TwoJoinNode):

        left_select_dict = {}
        left_exp_list = []
        __select_list_filter__(tree.select_list,tree.left_child.table_list,tree.left_child.table_alias_dict,left_select_dict,left_exp_list)

        if tree.where_condition is not None:
            pass
            #__add_func_to_select__(tree.where_condition.where_condition_exp,tree.left_child.table_list,tree.left_child.table_alias_dict,left_select_dict,left_exp_list)

        right_select_dict ={}
        right_exp_list = []
        __select_list_filter__(tree.select_list,tree.right_child.table_list,tree.right_child.table_alias_dict,right_select_dict,right_exp_list)

        if tree.where_condition is not None:
            pass
            #__add_func_to_select__(tree.where_condition.where_condition_exp,tree.right_child.table_list,tree.right_child.table_alias_dict,right_select_dict,right_exp_list)

        if tree.join_explicit is True:
            __add_func_to_select__(tree.join_condition.on_condition_exp,tree.left_child.table_list,tree.left_child.table_alias_dict,left_select_dict,left_exp_list)
            __add_func_to_select__(tree.join_condition.on_condition_exp,tree.right_child.table_list,tree.right_child.table_alias_dict,right_select_dict,right_exp_list)
        elif tree.join_condition is not None and not isinstance(tree.join_condition, str):
            __add_func_to_select__(tree.join_condition.where_condition_exp,tree.left_child.table_list,tree.left_child.table_alias_dict,left_select_dict,left_exp_list)
            __add_func_to_select__(tree.join_condition.where_condition_exp,tree.right_child.table_list,tree.right_child.table_alias_dict,right_select_dict,right_exp_list)
            if tree.where_condition is not None and tree.where_condition.where_condition_exp is not None:
                __add_func_to_select__(tree.where_condition.where_condition_exp,tree.left_child.table_list,tree.left_child.table_alias_dict,left_select_dict,left_exp_list)
                __add_func_to_select__(tree.where_condition.where_condition_exp,tree.right_child.table_list,tree.right_child.table_alias_dict,right_select_dict,right_exp_list)

        if tree.left_child.select_list is None:
            tree.left_child.select_list = FirstStepSelectList(None)

        if isinstance(tree.left_child,SelectProjectNode):
            new_list = []
            new_dict = {}
            table_schema = lookup_a_table(tree.left_child.table_alias)
            if table_schema is None:
                print >>sys.stderr,"Internal Error:column_filtering"
                exit(29)
            for x in table_schema.column_list:
                tmp_bool = False
                for tmp in left_exp_list:
                    if x.column_name == tmp.column_name and tmp.table_name == table_schema.table_name:
                        tmp_bool = True
                        break
                if tmp_bool == True:
                    new_list.append(tmp)
                    new_dict[tmp] = None
            tree.left_child.select_list.dict_exp_and_alias = new_dict
            tree.left_child.select_list.tmp_exp_list = new_list

        else:
            tree.left_child.select_list.dict_exp_and_alias = left_select_dict
            tree.left_child.select_list.tmp_exp_list = left_exp_list

        if tree.right_child.select_list is None:
            tree.right_child.select_list = FirstStepSelectList(None)

        if isinstance(tree.right_child,SelectProjectNode):
            new_list = []
            new_dict = {}
            table_schema = lookup_a_table(tree.right_child.table_alias)
            if table_schema is None:
                print >>sys.stderr,"Internal Error:column_filtering"
                exit(29)
            for x in table_schema.column_list:
                tmp_bool = False
                for tmp in right_exp_list:
                    if x.column_name == tmp.column_name and tmp.table_name == table_schema.table_name:
                        tmp_bool = True
                        break
                if tmp_bool == True:
                    new_list.append(tmp)
                    new_dict[tmp] = None
            tree.right_child.select_list.dict_exp_and_alias = new_dict
            tree.right_child.select_list.tmp_exp_list = new_list

        else:
            tree.right_child.select_list.dict_exp_and_alias = right_select_dict
            tree.right_child.select_list.tmp_exp_list = right_exp_list

        # if no parent or parent is OrderByNode
        # we need to do column filtering and process function in TableNode
        new_select_dict = {}
        new_exp_list = []
        if tree.parent == None or isinstance(tree.parent,OrderByNode): 
            # column filtering     
            if tree.select_list is not None:
                for exp in tree.select_list.tmp_exp_list:
                    if isinstance(exp,YRawColExp):
                        tmp_bool = False
                        for tmp in new_exp_list:
                            if not isinstance(tmp,YRawColExp):
                                continue
                            if tmp.column_name == exp.column_name and tmp.table_name == exp.table_name:
                                tmp_bool = True
                                break

                        if tmp_bool is False:
                            new_exp = copy.deepcopy(exp)
                            new_exp_list.append(new_exp)
                            new_select_dict[new_exp] = tree.select_list.dict_exp_and_alias[exp]

                    elif isinstance(exp,YFuncExp):

                        col_list = []
                        __get_func_para__(exp,col_list)
                        for tmp in col_list:
                            tmp_bool = False
                            for x in new_exp_list:
                                if not isinstance(x,YRawColExp):
                                    continue
                                if x.column_name == tmp.column_name and x.table_name == tmp.table_name:
                                    tmp_bool = True
                                    break

                            if tmp_bool is False:
                                new_exp = copy.deepcopy(tmp)
                                new_exp_list.append(new_exp)
                                new_select_dict[new_exp] = None
            
            tree.select_list.dict_exp_and_alias = new_select_dict
            tree.select_list.tmp_exp_list = new_exp_list
        
        column_filtering(tree.left_child)
        column_filtering(tree.right_child)

    elif isinstance(tree,SelectProjectNode):

        new_select_dict = {}
        new_exp_list = []

        if tree.select_list is None or tree.child.select_list is None:
            print >>sys.stderr,"Internal Error:column_filtering"
            exit(29)
########shouldn't change the select_list of the sp. it may be used when generating index

        child_exp_list = tree.child.select_list.tmp_exp_list
        child_exp_dict = tree.child.select_list.dict_exp_and_alias

        for exp in tree.select_list.tmp_exp_list:
            if isinstance(exp,YRawColExp):
                for x in child_exp_list:
                    if isinstance(x,YRawColExp):
                        if child_exp_dict[x] == exp.column_name:
                            if x not in new_exp_list:
                                new_exp_list.append(x)
                                new_select_dict[x] = exp.column_name
                            break

                        if exp.column_name == x.column_name:
                            if x not in new_exp_list:
                                new_exp_list.append(x)
                                new_select_dict[x] = None
                            break
                    elif isinstance(x,YFuncExp):
                        if child_exp_dict[x] == exp.column_name:
                            if x not in new_exp_list:
                                new_exp_list.append(x)
                                new_select_dict[x] = None
                            break

            elif isinstance(exp,YFuncExp):
                col_list = []
                __get_func_para__(exp,col_list)
                for tmp in col_list:
                    tmp.table_name = ""

                new_exp_list.append(exp)
                new_select_dict[exp] = None

            else:
                new_exp_list.append(exp)
                new_select_dict[exp] = None

        # add child select columns that used in child group by
        if isinstance(tree.child, GroupByNode):
            for exp in tree.child.group_by_clause.groupby_exp_list:
                for x in tree.child.select_list.tmp_exp_list:
                    if isinstance(x, YRawColExp) and isinstance(exp, YRawColExp) and x.column_name == exp.column_name and x not in new_exp_list:
                        new_exp_list.append(x)
                        new_select_dict[x] = exp.column_name
                        break

        tree.child.select_list.tmp_exp_list = new_exp_list
        tree.child.select_list.dict_exp_and_alias = new_select_dict

        column_filtering(tree.child)


def __gen_col_table_name__(exp,table_list,table_alias_dict):

    if isinstance(exp,YRawColExp) is False:
        return

    if exp.table_name != "":
        table_schema = lookup_a_table(exp.table_name)
        if table_schema is None:
            table_schema = lookup_a_table(table_alias_dict[exp.table_name])

        if table_schema is None:
            print >>sys.stderr,"Internal Error:__gen_col_table_name__"
            exit(29)

        exp.column_type = table_schema.get_column_type_by_name(exp.column_name)
        return

    if exp.column_name == "*":
        return

    col_res = lookup_a_column(exp.column_name)

    for tmp in col_res:
        if tmp.table_schema.table_name in table_list:
            exp.table_name = tmp.table_schema.table_name
            exp.column_type = tmp.table_schema.get_column_type_by_name(exp.column_name)
            return

        for x  in table_alias_dict.keys():
            if tmp.table_schema.table_name == table_alias_dict[x]:
                exp.table_name = x
                exp.column_type = tmp.table_schema.get_column_type_by_name(exp.column_name)
                return

def gen_table_name(tree):

    if tree.select_list is not None:
        exp_dict = tree.select_list.dict_exp_and_alias
        for exp in exp_dict.keys():
            if isinstance(exp,YRawColExp):
                __gen_col_table_name__(exp,tree.table_list,tree.table_alias_dict)

            elif isinstance(exp,YFuncExp):
                col_list = []
                __get_func_para__(exp,col_list)
                for tmp in col_list:
                    __gen_col_table_name__(tmp,tree.table_list,tree.table_alias_dict)

    if tree.where_condition is not None:
        col_list = []
        __get_func_para__(tree.where_condition.where_condition_exp,col_list)
        for tmp in col_list:
            __gen_col_table_name__(tmp,tree.table_list,tree.table_alias_dict)

    if isinstance(tree,TwoJoinNode):
        if tree.join_explicit is True:
            col_list = []
            __get_func_para__(tree.join_condition.on_condition_exp,col_list)
            for tmp in col_list:
                __gen_col_table_name__(tmp,tree.table_list,tree.table_alias_dict)


    if isinstance(tree,GroupByNode):
        if tree.group_by_clause is not None:
            for exp in tree.group_by_clause.groupby_exp_list:
                if isinstance(exp,YRawColExp):
                    __gen_col_table_name__(exp,tree.table_list,tree.table_alias_dict)

    if isinstance(tree,GroupByNode):
        gen_table_name(tree.child)

    elif isinstance(tree,OrderByNode):
        gen_table_name(tree.child)

    elif isinstance(tree,SelectProjectNode):
        gen_table_name(tree.child)

    elif isinstance(tree,TwoJoinNode):
        gen_table_name(tree.left_child)
        gen_table_name(tree.right_child)

def __groupby_func_name__(exp):
    if not isinstance(exp,YFuncExp):
        return None

    if exp.func_name in  agg_func_list:
        return exp.func_name

    for x in exp.parameter_list:
        if isinstance(x,YFuncExp):
            tmp_name = __groupby_func_name__(x)
            if tmp_name is not None:
                return tmp_name


def handle_select_star(tree):

    if tree.select_list is not None:

        select_dict = tree.select_list.dict_exp_and_alias
        exp_list = tree.select_list.tmp_exp_list

        new_select_dict = {}
        new_exp_list = []

        for exp in exp_list:
            if isinstance(exp,YRawColExp):
                if exp.column_name != "*":
                    new_exp = copy.deepcopy(exp)
                    new_exp_list.append(new_exp)
                    new_select_dict[new_exp] = select_dict[exp]

                else:
                    for tmp in tree.table_list:
                        table_schema = lookup_a_table(tmp)
                        if table_schema is None:
                            continue

                        for x in table_schema.column_list:
                            tmp_exp = YRawColExp(tmp,x.column_name)
                            new_exp_list.append(tmp_exp)
                            new_select_dict[tmp_exp] = None

                    for tmp in tree.table_alias_dict.keys():
                        table_schema = lookup_a_table(tree.table_alias_dict[tmp])
                        if table_schema is None:
                            continue

                        for x in table_schema.column_list:
                            tmp_exp = YRawColExp(tmp,x.column_name)
                            new_exp_list.append(tmp_exp)
                            new_select_dict[tmp_exp] = None

            elif isinstance(exp,YFuncExp):
                if __groupby_func_name__(exp) == "COUNT":
                    col_list = []
                    __get_func_para__(exp,col_list)
                    for x in col_list:
                        if x.column_name == "*":
                            func_obj = x.func_obj
                            new_cons = YConsExp(1,"INTEGER")
                            func_obj.replace(x,new_cons)
                    new_exp_list.append(exp)
                    new_select_dict[exp] = select_dict[exp]
                else:
                    new_exp = copy.deepcopy(exp)
                    new_exp_list.append(new_exp)
                    new_select_dict[new_exp] = select_dict[exp]

            else:
                new_exp = copy.deepcopy(exp)
                new_exp_list.append(new_exp)
                new_select_dict[new_exp] = select_dict[exp]

        tree.select_list.dict_exp_and_alias = new_select_dict
        tree.select_list.tmp_exp_list = new_exp_list

    if isinstance(tree,TableNode):
        return

    elif isinstance(tree,OrderByNode):
        handle_select_star(tree.child)

    elif isinstance(tree,SelectProjectNode):
        handle_select_star(tree.child)

    elif isinstance(tree,TwoJoinNode):
        handle_select_star(tree.left_child)
        handle_select_star(tree.right_child)

    elif isinstance(tree,GroupByNode):
        handle_select_star(tree.child)


###go down the tree as far as possible to find the original of the exp
###the type of tree can only be a GroupByNode or a 2JoinNode

def __trace_to_leaf__(tree,exp,join_bool):

    if not isinstance(exp,YRawColExp):
        return exp

    if isinstance(tree,GroupByNode):
        index = exp.column_name
        tmp_exp = tree.child.select_list.tmp_exp_list[index]
        new_exp = copy.deepcopy(__trace_to_leaf__(tree.child,tmp_exp,False))
        return new_exp

    elif isinstance(tree,TwoJoinNode):
        index = exp.column_name
        tn = exp.table_name
        if tn == "LEFT":
            if join_bool is True and isinstance(tree.left_child,TableNode):
                tmp_exp = copy.deepcopy(exp)
                tmp_exp.table_name = tree.left_child.select_list.tmp_exp_list[0].table_name
                new_exp = copy.deepcopy(__trace_to_leaf__(tree.left_child,tmp_exp,False))
            else:
                index = exp.column_name
                tmp_exp = tree.left_child.select_list.tmp_exp_list[index]
                new_exp = copy.deepcopy(__trace_to_leaf__(tree.left_child,tmp_exp,False))
        else:
            if join_bool is True and isinstance(tree.right_child,TableNode):
                tmp_exp = copy.deepcopy(exp)
                tmp_exp.table_name = tree.right_child.select_list.tmp_exp_list[0].table_name
                new_exp = copy.deepcopy(__trace_to_leaf__(tree.right_child,tmp_exp,False))
            else:
                index = exp.column_name
                tmp_exp = tree.right_child.select_list.tmp_exp_list[index]
                new_exp = copy.deepcopy(__trace_to_leaf__(tree.right_child,tmp_exp,False))

        return new_exp

    elif isinstance(tree,TableNode):
        new_exp = copy.deepcopy(exp)
        new_exp.table_name = tree.table_name
        return new_exp

    elif isinstance(tree,SelectProjectNode):
        index = exp.column_name
        tmp_exp = tree.child.select_list.tmp_exp_list[index]
        new_exp = __trace_to_leaf__(tree.child,tmp_exp,False)
        return new_exp

def list_contain_exp(exp_list,exp):

    for x in exp_list:
        if x.compare(exp):
            return True

    return False

def ysmart_get_schema(schema):

    return process_schema_in_a_file(schema)


def process_the_plan_tree(tree):

    gen_project_list(tree)

    search_external_cols(tree, tree)

    if check_schema(tree) == -1:
        tree = None
        return

    handle_select_star(tree)

    gen_table_name(tree)

    predicate_pushdown(tree)

    gen_project_func(tree)

    column_filtering(tree)

    gen_table_name(tree)

    gen_column_index(tree)

def __traverse_exp_filter__(exp, res_list, filter_func):
    if filter_func(exp):
        res_list.append(exp)

    if isinstance(exp, YFuncExp):
        map(lambda par : __traverse_exp_filter__(par, res_list, filter_func), exp.parameter_list)

def __traverse_exp_map__(exp, map_func):
    map_func(exp)

    if isinstance(exp, YFuncExp):
        map(lambda par : __traverse_exp_map__(par, map_func), exp.parameter_list)

def search_external_cols(tree, root):

    if isinstance(tree, GroupByNode) or isinstance(tree, OrderByNode) or isinstance(tree, SelectProjectNode):
        search_external_cols(tree.child, root)

    elif isinstance(tree, TwoJoinNode) or isinstance(tree, TableNode):

        if isinstance(tree, TwoJoinNode):
            search_external_cols(tree.left_child, root)
            search_external_cols(tree.right_child, root)

        if tree.where_condition is None:
            return

        exp = tree.where_condition.where_condition_exp
        table_list = list(set().union(tree.table_list, tree.table_alias_dict.keys()))
        other_table_list = filter(lambda t : t not in table_list, global_table_dict.keys())

        all_column_exps = []

        __traverse_exp_filter__(exp, all_column_exps, lambda e : isinstance(e, YRawColExp))

        # external columns are columns not in the table list
        external_cols = filter(lambda e : all( not column_in_table(e.column_name, t) for t in table_list), all_column_exps)

        for col in external_cols:
            external_table_found = False
            for t in other_table_list:
                if column_in_table(col.column_name, t):
                    col.table_name = t
                    col.column_type = global_table_dict[t].get_column_type_by_name(col.column_name)
                    external_table_found = True
            if not external_table_found:
                print "ERROR: Unknown column " + col.column_name
                exit(99)

        # setup in a dictionary at the root node
        for col in external_cols:
            root.dynamic_values[col.column_name] = col

        def replace_cols_in_a_func_exp(_func_exp):
            if not isinstance(_func_exp, YFuncExp):
                return
            for par in _func_exp.parameter_list:
                if par in external_cols:
                    cons = YConsExp(None, par.column_type)
                    cons.ref_col = par
                    parent_func = _func_exp.func_obj
                    _func_exp.replace(par, cons)
                    _func_exp.func_obj = parent_func

        # replace all exteranl colexp with consexp
        __traverse_exp_map__(exp, lambda e : replace_cols_in_a_func_exp(e))

def ysmart_tree_gen(schema,xml_file):

    process_schema_in_a_file(schema)

    if xml_file is None:
        return None

    thenode = get_the_select_node_from_a_file(xml_file)

    node = build_plan_tree_from_a_select_node(thenode)

    return node

def eval_exp_list(exp_list):
    return map(lambda exp: exp.evaluate(), exp_list)
